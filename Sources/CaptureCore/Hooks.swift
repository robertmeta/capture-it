import AVFoundation
import Darwin
import Foundation

/// Selected executables to run after audio and transcript files have finalized.
public struct HookOptions: Sendable {
    public var executables: [URL]
    public var timeout: Double

    public init(executables: [URL] = [], timeout: Double = 300) {
        self.executables = executables; self.timeout = timeout
    }

    func validate() throws {
        guard timeout.isFinite, timeout > 0 else { throw CaptureError.message("--hook-timeout must be a positive finite number") }
        for executable in executables {
            guard !executable.path.contains("\0"), FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw CaptureError.message("Hook is not executable: \(executable.path). Supply an executable file, not a shell command.")
            }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &directory), !directory.boolValue else {
                throw CaptureError.message("Hook must be an executable file: \(executable.path)")
            }
        }
    }
}

/// Setup opts into the first-party hook by installing it beside the CLI.
enum InstalledHooks {
    static func fluid(beside executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let executable else { return nil }
        let hook = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("capture-it-fluid")
        return FileManager.default.fileExists(atPath: hook.path) ? hook : nil
    }
}

/// Versioned file handoff. Paths are absolute; absent transcript artifacts are nil.
struct HookEvent: Codable {
    let version: Int
    let event: String
    let sessionDirectory: String
    let sessionManifest: String
    let wav: String
    let transcript: String?
    let segments: String?
    let transcriptSummary: String?
    let transcriptComplete: Bool?
    let recordingStatus: String
    let transcriptionStatus: String
    var meeting: MeetingMetadata? = nil

    static func load(session: URL, transcriptDirectory: URL?) throws -> HookEvent {
        let directory = session.standardizedFileURL
        let metadata = directory.appendingPathComponent("session.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: metadata))
        guard manifest.recording == "complete" || manifest.recording == "failed",
              manifest.chunks.count == 1, let chunk = manifest.chunks.first,
              chunk.closed, chunk.file == "recording.wav", chunk.frames > 0 else {
            throw CaptureError.message("Hooks require one finalized recording.wav; recording is unchanged")
        }
        let wav = directory.appendingPathComponent(chunk.file)
        let audio = try AVAudioFile(forReading: wav)
        guard audio.length == chunk.frames else { throw CaptureError.message("Saved WAV frame count differs from session metadata") }
        let transcripts = (transcriptDirectory ?? directory).standardizedFileURL
        func existing(_ name: String) -> String? {
            let path = transcripts.appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        let text = existing("transcript.txt")
        if transcriptDirectory != nil, text == nil { throw CaptureError.message("No transcript.txt in \(transcripts.path)") }
        let summary = existing("transcript.json")
        struct Summary: Decodable { let complete: Bool }
        let complete = try summary.map { try JSONDecoder().decode(Summary.self, from: Data(contentsOf: URL(fileURLWithPath: $0))).complete }
        return HookEvent(version: 1, event: "session-finished", sessionDirectory: directory.path,
                         sessionManifest: metadata.path, wav: wav.path, transcript: text,
                         segments: existing("transcript.jsonl"), transcriptSummary: summary,
                         transcriptComplete: complete, recordingStatus: manifest.recording,
                         transcriptionStatus: manifest.transcription, meeting: manifest.meeting)
    }
}

struct HookResult: Codable {
    let executable: String
    var status: String
    var exitCode: Int32?
    var terminationSignal: Int32?
    var message: String?
    var duration: Double = 0
    let outputDirectory: String
}

/// Child processes run only after saved artifacts are durable. No pipe connects
/// agent output to transcript stdout, and no shell interprets executable paths.
enum HookRunner {
    static func run(session: URL, transcriptDirectory: URL? = nil, options: HookOptions, shutdown: ShutdownState) async throws -> Bool {
        guard !options.executables.isEmpty else { return true }
        try options.validate()
        // On a forced recording exit, do not wait for or inspect partial text.
        let input = shutdown.interrupted ? nil : try HookEvent.load(session: session, transcriptDirectory: transcriptDirectory)
        let runDirectory = session.standardizedFileURL.appendingPathComponent("hooks/\(UUID().uuidString)")
        try privateDirectory(runDirectory)
        let inputURL = runDirectory.appendingPathComponent("input.json")
        if let input { try atomicJSON(input, at: inputURL) }
        struct Report: Encodable { let version = 1; let results: [HookResult] }
        var results: [HookResult] = []
        diagnostic("Post-session hooks → \(runDirectory.path); Ctrl-C cancels remaining hooks")
        for (index, executable) in options.executables.enumerated() {
            let output = runDirectory.appendingPathComponent(String(format: "%03d", index + 1))
            try privateDirectory(output)
            var result = HookResult(executable: executable.path, status: "skipped", outputDirectory: output.path)
            if shutdown.interrupted {
                result.message = "User interrupted; saved audio retained"
            } else {
                diagnostic("Running hook \(index + 1)/\(options.executables.count): \(executable.path)")
                let began = Date()
                do { result = try await execute(executable: executable, input: inputURL, event: input!, output: output, timeout: options.timeout, shutdown: shutdown) }
                catch { result.status = "failed"; result.message = String(describing: error) }
                result.duration = Date().timeIntervalSince(began)
            }
            results.append(result)
            try atomicJSON(Report(results: results), at: runDirectory.appendingPathComponent("result.json"))
            diagnostic("Hook \(index + 1): \(result.status)\(result.message.map { "; \($0)" } ?? "")")
        }
        return results.allSatisfy { $0.status == "complete" }
    }

    private static func execute(executable: URL, input: URL, event: HookEvent, output: URL, timeout: Double, shutdown: ShutdownState) async throws -> HookResult {
        let stdout = try createPrivateFile(output.appendingPathComponent("stdout.log"))
        let stderr = try createPrivateFile(output.appendingPathComponent("stderr.log"))
        defer { try? stdout.close(); try? stderr.close() }
        var environment = ProcessInfo.processInfo.environment
        environment["CAPTURE_IT_EVENT"] = input.path
        environment["CAPTURE_IT_SESSION"] = event.sessionDirectory
        environment["CAPTURE_IT_WAV"] = event.wav
        environment["CAPTURE_IT_TRANSCRIPT"] = event.transcript ?? ""
        environment["CAPTURE_IT_HOOK_OUTPUT"] = output.path
        let pid = try spawn(executable: executable.path, arguments: [input.path], environment: environment,
                            stdout: stdout.fileDescriptor, stderr: stderr.fileDescriptor)
        var result = HookResult(executable: executable.path, status: "running", outputDirectory: output.path)
        let began = ContinuousClock.now
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                // Hooks may not leave background descendants behind.
                _ = kill(-pid, SIGKILL)
                if status & 0x7f == 0 {
                    result.exitCode = (status >> 8) & 0xff
                    result.status = result.exitCode == 0 ? "complete" : "failed"
                } else {
                    result.terminationSignal = status & 0x7f
                    result.status = "failed"
                }
                break
            }
            if waited < 0, errno != EINTR {
                let failure = errno
                _ = kill(-pid, SIGKILL)
                throw CaptureError.message("Cannot wait for hook: \(String(cString: strerror(failure)))")
            }
            let elapsed = began.duration(to: .now).components
            let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            if shutdown.interrupted || elapsedSeconds >= timeout {
                result.status = shutdown.interrupted ? "interrupted" : "timed-out"
                result.message = shutdown.interrupted ? "User interrupted" : "Exceeded \(timeout)s timeout"
                _ = kill(-pid, SIGTERM)
                try? await Task.sleep(for: .milliseconds(200))
                _ = kill(-pid, SIGKILL)
                // The child is now killed; reap without blocking the audio path.
                while waitpid(pid, &status, 0) < 0, errno == EINTR { }
                result.terminationSignal = status & 0x7f
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try stdout.synchronize(); try stderr.synchronize()
        return result
    }

    private static func spawn(executable: String, arguments: [String], environment: [String: String], stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ code: Int32) throws {
            guard code == 0 else { throw CaptureError.message("Cannot launch hook: \(String(cString: strerror(code)))") }
        }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO))
        var defaults: sigset_t = 0
        for number in [SIGINT, SIGTERM, SIGPIPE, SIGXFSZ] { sigaddset(&defaults, number) }
        var mask: sigset_t = 0
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        let argv = ([executable] + arguments).map { strdup($0)! } + [nil]
        let env = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)")! } + [nil]
        defer { for pointer in argv + env { free(pointer) } }
        var pid: pid_t = 0
        try argv.withUnsafeBufferPointer { args in
            try env.withUnsafeBufferPointer { vars in
                try check(posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, vars.baseAddress!))
            }
        }
        return pid
    }
}
