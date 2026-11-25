import AVFoundation
import Foundation

public enum CLI {
    public static let help = """
    capture-it \(captureItVersion) — app audio + microphone, WAV + live local transcript

    Usage:
      capture-it NAME_OR_PATTERN [record options]
      capture-it apps [--json]
      capture-it devices [--json]
      capture-it doctor [--locale en-US] [--json]
      capture-it setup-speech [--locale en-US]   # explicit Apple model download
      capture-it setup-accessibility           # request window-title permission
      capture-it record [NAME_OR_PATTERN | --app NAME_OR_PATTERN] [options]
      capture-it transcribe SESSION_DIRECTORY [--out DIRECTORY] [--locale en-US]
      capture-it hooks SESSION_DIRECTORY [--hook EXECUTABLE ...]

      capture-it people                         # remembered names and sample counts
      capture-it speakers SESSION_DIRECTORY [--run UUID/NNN]
      capture-it speakers SESSION_DIRECTORY --listen SPEAKER_ID
      capture-it speakers SESSION_DIRECTORY --assign SPEAKER_ID --name "Joe Smith"

    Naming a speaker saves local voice samples for recognition in future recordings.
    The speaker list shows IDs, names and example times after FluidAudio finishes.

    Record options:
      --app NAME_OR_PATTERN  Name/bundle substring or quoted * / ? wildcard
                             One match auto-selects; multiple matches prompt
      --out DIRECTORY        Default: ./SEARCH-yyyyMMdd-HHmmss (new session folder)
      --mic DEVICE_UID       Override app input detection / system-default fallback
      --locale LOCALE        Default: en-US
      --duration SECONDS     Stop automatically; otherwise q or Ctrl-C stops and saves
      --no-transcribe        Record audio without speech recognition
      --no-fluid             Skip automatic FluidAudio speaker labeling
      --hook EXECUTABLE      Run after saved files finalize (repeatable; no shell)
      --hook-timeout SECONDS Per-hook limit; default: 900 with installed FluidAudio, else 300
      --title TITLE          Explicit meeting title; otherwise best-effort AX title

    Hook options also apply to transcribe and hooks. `hooks --transcript DIRECTORY`
    selects a saved transcript directory; otherwise use the session's transcript.

    Final transcript lines are teed to stdout and DIRECTORY/transcript.txt.
    DIRECTORY/recording.wav has three channels: app left, app right, microphone.
    One mono downmix feeds a single live transcription stream.
    WAV, transcript file and stdout workers run independently with bounded queues.
    Status and errors go to stderr. Capture/speech never upload audio.
    After make setup, the installed FluidAudio hook runs locally after saving.
    First Ctrl-C saves WAV, finishes speech, then labels; Ctrl-C again skips/cancels.
    In an interactive recording, q (no Enter) starts the same graceful stop.
    Repeated q never cancels finishing work. Escape has no stop action.
    FluidAudio runs before explicit hooks unless you place it explicitly yourself.
    Explicit hooks run your code and may use remote agents.
    Exit: 0 complete, 1 recording/usage failure, 2 saved audio/partial transcript or output.
    """

    public static func run(_ arguments: [String]) async throws -> Int32 {
        guard let first = arguments.first else { print(help); return 0 }
        if first == "--help" || first == "-h" || arguments.dropFirst().contains("--help") { print(help); return 0 }
        if first == "--version" { print(captureItVersion); return 0 }
        let commands: Set<String> = ["apps", "devices", "doctor", "setup-speech", "setup-accessibility", "record", "transcribe", "hooks", "speakers", "people"]
        let command = commands.contains(first) ? first : "record"
        let args = try Arguments(commands.contains(first) ? Array(arguments.dropFirst()) : arguments)
        switch command {
        case "setup-accessibility":
            try args.validate(allowed: [])
            if MeetingObserver.requestPermission() { diagnostic("Accessibility is ready for selected-app window titles") }
            else {
                diagnostic("Allow this terminal/CLI under System Settings → Privacy & Security → Accessibility, then rerun doctor. Audio capture works without it.")
                return 2
            }
        case "setup-speech":
            try args.validate(allowed: ["--locale"])
            diagnostic("Installing on-device language assets from Apple; no audio is uploaded")
            try await LocalSpeech.install(locale: args.values["--locale"] ?? "en-US")
            diagnostic("Local speech assets are ready")
        case "apps":
            try args.validate(allowed: ["--json"])
            let apps = try Hardware.apps()
            if args.flags.contains("--json") { try json(apps) }
            else { for app in apps { print("\(app.bundleID)\tpid=\(app.pid)\t\(app.playing ? "playing" : "idle")\t\(app.name)") } }
        case "devices":
            try args.validate(allowed: ["--json"])
            let devices = try Hardware.devices()
            if args.flags.contains("--json") { try json(devices) }
            else { for device in devices { print("\(device.uid)\t\(device.isDefault ? "default" : "")\t\(device.name)") } }
        case "doctor":
            try args.validate(allowed: ["--json", "--locale"])
            let speech = await LocalSpeech.status(locale: args.values["--locale"] ?? "en-US")
            let screenRecordingGranted = ScreenCaptureAccess.screenRecordingGranted
            if args.flags.contains("--json") {
                struct Report: Encodable {
                    let available: Bool; let locale: String; let assets: String; let ready: Bool
                    let accessibilityTrusted: Bool
                    let screenRecordingGranted: Bool
                    let fluidHook: String?
                }
                try json(Report(available: speech.available, locale: speech.locale, assets: speech.assets,
                                ready: speech.ready, accessibilityTrusted: MeetingObserver.isTrusted,
                                screenRecordingGranted: screenRecordingGranted,
                                fluidHook: InstalledHooks.fluid()?.path))
            }
            else {
                print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
                print("Microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
                print("Screen Recording permission for this launch: \(screenRecordingGranted ? "granted" : "not granted")")
                print("On-device speech: \(speech.ready ? "ready" : speech.assets) (\(speech.locale))")
                print("Automatic model downloads: disabled; run setup-speech to explicitly install assets")
                print("Accessibility for window titles: \(MeetingObserver.isTrusted ? "ready" : "not granted; run setup-accessibility or use --title")")
                print("FluidAudio: \(InstalledHooks.fluid().map { "installed at \($0.path); runs after saving (--no-fluid to skip)" } ?? "not installed; run make setup")")
            }
        case "people", "speakers":
            let helperArguments: [String]
            if command == "people" {
                try args.validate(allowed: [])
                helperArguments = ["--people"]
            } else {
                try args.validate(allowed: ["--run", "--listen", "--assign", "--name"], positionals: 1...1)
                let assign = args.values["--assign"]
                let listen = args.values["--listen"]
                guard (assign == nil) == (args.values["--name"] == nil), assign == nil || listen == nil,
                      assign != "", listen != "" else {
                    throw CaptureError.message("Use --listen ID or --assign ID --name NAME")
                }
                helperArguments = ["--speakers", args.positionals[0], args.values["--run"] ?? "",
                                   assign ?? listen ?? ""] + (args.values["--name"].map { [$0] } ?? [])
            }
            guard let helper = InstalledHooks.fluid() else {
                throw CaptureError.message("Speaker review needs the installed capture-it-fluid helper. Run make setup.")
            }
            let process = Process()
            process.executableURL = helper
            process.arguments = helperArguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        case "record":
            try args.validate(allowed: ["--app", "--out", "--mic", "--locale", "--duration", "--no-transcribe", "--no-fluid", "--hook", "--hook-timeout", "--title"], positionals: 0...1)
            let hooks = try args.hookOptions()
            if let title = args.values["--title"], MeetingTitlePolicy.clean(title).isEmpty { throw CaptureError.message("--title must not be empty") }
            guard args.values["--app"] == nil || args.positionals.isEmpty else { throw CaptureError.message("Use either a positional app name or --app, not both") }
            guard let app = args.values["--app"] ?? args.positionals.first else { throw CaptureError.message("Choose an app: capture-it teams, or capture-it record --app NAME") }
            var duration: Double?
            if let raw = args.values["--duration"] {
                guard let value = Double(raw), value.isFinite, value > 0 else { throw CaptureError.message("--duration must be a positive finite number") }
                duration = value
            }
            let selected = try await AppSelection.resolve(app)
            let output = args.values["--out"].map { URL(fileURLWithPath: $0) } ?? CaptureDefaults.output(query: app, appName: selected.name)
            return try await Sessions.record(RecordOptions(app: selected.bundleID, output: output, microphone: args.values["--mic"], locale: args.values["--locale"] ?? "en-US", transcribe: !args.flags.contains("--no-transcribe"), duration: duration, processID: selected.pid, hooks: hooks, title: args.values["--title"]))
        case "transcribe":
            try args.validate(allowed: ["--out", "--locale", "--no-fluid", "--hook", "--hook-timeout"], positionals: 1...1)
            let hooks = try args.hookOptions()
            return try await Sessions.transcribe(session: URL(fileURLWithPath: args.positionals[0]), output: args.values["--out"].map { URL(fileURLWithPath: $0) }, locale: args.values["--locale"] ?? "en-US", hooks: hooks)
        case "hooks":
            try args.validate(allowed: ["--hook", "--hook-timeout", "--transcript", "--no-fluid"], positionals: 1...1)
            let hooks = try args.hookOptions(required: true)
            let stop = StopSignal()
            stop.state.beginDraining()
            return try await HookRunner.run(session: URL(fileURLWithPath: args.positionals[0]), transcriptDirectory: args.values["--transcript"].map { URL(fileURLWithPath: $0) }, options: hooks, shutdown: stop.state) ? 0 : 2
        default: throw CaptureError.message("Unknown command \(command). Run capture-it --help.")
        }
        return 0
    }

    private static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

private struct Arguments {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []
    var hooks: [String] = []
    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value.hasPrefix("--") {
                if value == "--hook" {
                    index += 1
                    guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw CaptureError.message("Missing value for --hook") }
                    hooks.append(arguments[index]); index += 1; continue
                }
                guard values[value] == nil, !flags.contains(value) else { throw CaptureError.message("Repeated option \(value)") }
                if value == "--json" || value == "--no-transcribe" || value == "--no-fluid" { flags.insert(value) }
                else {
                    index += 1
                    guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw CaptureError.message("Missing value for \(value)") }
                    values[value] = arguments[index]
                }
            } else { positionals.append(value) }
            index += 1
        }
    }
    func validate(allowed: Set<String>, positionals count: ClosedRange<Int> = 0...0) throws {
        let supplied = Set(values.keys).union(flags).union(hooks.isEmpty ? [] : ["--hook"])
        guard supplied.isSubset(of: allowed) else { throw CaptureError.message("Unsupported option: \(supplied.subtracting(allowed).sorted().joined(separator: ", "))") }
        guard count.contains(positionals.count) else { throw CaptureError.message("Expected \(count) positional argument(s). Run capture-it --help.") }
    }

    func hookOptions(required: Bool = false) throws -> HookOptions {
        var executables = hooks.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let fluid = flags.contains("--no-fluid") ? nil : InstalledHooks.fluid()
        if let fluid, !executables.contains(where: { $0.resolvingSymlinksInPath() == fluid.resolvingSymlinksInPath() }) {
            executables.insert(fluid, at: 0)
        }
        if required || values["--hook-timeout"] != nil {
            guard !executables.isEmpty else { throw CaptureError.message("Install FluidAudio with make setup, or supply --hook EXECUTABLE") }
        }
        let raw = values["--hook-timeout"] ?? (fluid == nil ? "300" : "900")
        guard let timeout = Double(raw) else { throw CaptureError.message("--hook-timeout must be a positive finite number") }
        let options = HookOptions(executables: executables, timeout: timeout)
        try options.validate()
        return options
    }
}
