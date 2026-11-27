import CapturePaths
import AVFoundation
import AppKit
import Darwin
import Foundation
import Synchronization

public struct RecordOptions: Sendable {
    public var app: String
    public var output: URL
    public var microphone: String?
    public var locale: String
    public var transcribe: Bool
    public var duration: Double?
    public var processID: pid_t?
    public var hooks: HookOptions
    public var title: String?
    var container: RecordingContainer = .m4a
    var targets: [AppChoice] = []
    var meetingStem: String?
    var numberFirstMeeting = false
    public init(app: String, output: URL, microphone: String? = nil, locale: String = "en-US", transcribe: Bool = true, duration: Double? = nil, processID: pid_t? = nil, hooks: HookOptions = HookOptions(), title: String? = nil) {
        self.app = app; self.output = output; self.microphone = microphone
        self.locale = locale; self.transcribe = transcribe; self.duration = duration
        self.processID = processID
        self.hooks = hooks
        self.title = title
    }
}

final class StopSignal: @unchecked Sendable {
    let state = ShutdownState()
    let received = Atomic<Int32>(0)
    private var sources: [DispatchSourceSignal] = []
    init() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if !state.requested { received.store(number, ordering: .releasing) }
                state.request(count: source.data)
            }
            source.resume(); sources.append(source)
        }
    }
    deinit {
        for source in sources { source.setEventHandler {}; source.cancel() }
    }
}

func diagnostic(_ text: String) {
    // Control plane only. Transcript stdout has a separate bounded worker.
    let data = Data("capture-it: \(text)\n".utf8)
    data.withUnsafeBytes { bytes in
        _ = Darwin.write(STDERR_FILENO, bytes.baseAddress!, bytes.count)
    }
}

public enum Sessions {
    public static func record(_ options: RecordOptions) async throws -> Int32 {
        try options.hooks.validate()
        let stop = StopSignal()
        let nextMeeting = Atomic<Bool>(false)
        var keys: RecordingKeys?
        defer { keys?.stop(); withExtendedLifetime(stop) {} }
        if let title = options.title, MeetingTitlePolicy.clean(title).isEmpty { throw CaptureError.message("--title must not be empty") }
        let targets = options.targets.isEmpty ? [AppChoice(name: options.app, bundleID: options.app, pid: options.processID ?? 0)] : options.targets
        let microphone = try Hardware.selectMicrophone(explicitUID: options.microphone, targets: targets)
        diagnostic("Microphone: \(microphone.device.name) (\(microphone.reason))")
        let primary = targets.count == 1 ? targets.first : nil
        var observer = MeetingObserver(target: primary, title: options.title)
        defer { observer.stop() }
        let epoch = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        var meeting = try MeetingRecording(options: options, targets: targets, microphone: microphone, epoch: epoch, meeting: observer.snapshot, first: true)
        let inputs = Source.inputs.map { CaptureInput(source: $0, epoch: epoch) }
        func counters() -> [String: Int64] {
            Dictionary(uniqueKeysWithValues: inputs.map { ($0.source.rawValue, $0.receivedFrames.load(ordering: .acquiring)) })
        }
        var baseline = counters()
        func frames() -> [String: Int64] {
            var result = counters()
            for (key, initial) in baseline { result[key, default: 0] -= initial }
            return result
        }
        let engineIssues = Issues()
        let assembler = ChannelAssembler(inputs: inputs, output: meeting.lane, epoch: epoch, issues: engineIssues)
        let capture = NativeCapture(targets: targets, microphone: microphone.device, lane: inputs[0], micLane: inputs[1])
        var started = false
        var failed = false
        var processing: Task<ProcessedMeeting, Never>?
        var reason = "quit"
        do {
            await authorizeAndReport(microphone: microphone.device)
            try await MicrophoneAccess.authorize()
            if stop.state.requested { throw CaptureError.message("Stopped before recording began") }
            diagnostic("Starting selected-app audio capture; allow macOS Screen & System Audio Recording access if prompted")
            let filter = try await capture.prepare()
            if stop.state.requested { throw CaptureError.message("Stopped before recording began") }
            try await meeting.start(options: options)
            assembler.start()
            try await capture.start(filter: filter)
            started = true
            meeting.manifest.recording = "recording"
            try meeting.save()
            keys = RecordingKeys(shutdown: stop.state) { nextMeeting.store(true, ordering: .releasing) }
            diagnostic("Recording \(targets.map(\.name).joined(separator: " + ")) + \(microphone.device.name) → \(meeting.directory.path)")
            diagnostic("Transcription: \(meeting.manifest.transcription). \(keys == nil ? "Ctrl-C saves and quits" : "[q] Quit   [n] New meeting"). Ctrl-C again during shutdown cancels processing.")
            if let title = observer.snapshot.title { diagnostic("Title (\(observer.snapshot.source ?? "unknown")): \(title)") }
            else if observer.snapshot.status == "permission-required" { diagnostic("Meeting title unavailable: allow Accessibility with setup-accessibility, or supply --title") }
            let began = ContinuousClock.now
            var lastCheck = Date.distantPast
            while !stop.state.requested {
                if let duration = options.duration, began.duration(to: .now) >= .seconds(duration) { reason = "duration"; break }
                if assembler.failed.load(ordering: .acquiring) { throw CaptureError.message(engineIssues.all.last ?? "Audio channel assembly failed") }
                for input in inputs where input.overflow.load(ordering: .acquiring) || input.copyFailure.load(ordering: .acquiring) {
                    throw CaptureError.message("\(input.source.rawValue) capture could not preserve every audio buffer; recording stopped")
                }
                if meeting.lane.recordingOverflow.load(ordering: .acquiring) || meeting.lane.copyFailure.load(ordering: .acquiring) {
                    throw CaptureError.message("Recording could not persist every audio buffer; recording stopped")
                }
                if Date().timeIntervalSince(lastCheck) >= 1 {
                    try await capture.refresh()
                    try meeting.checkpoint(meeting: observer.snapshot, frames: frames())
                    lastCheck = Date()
                }
                let savedFrames = meeting.lane.chunks.first?.frames ?? 0
                let rollover = CaptureDefaults.needsRollover(frames: savedFrames)
                if savedFrames > 0 && (nextMeeting.exchange(false, ordering: .acquiringAndReleasing) || rollover) {
                    let next = try MeetingRecording(options: options, targets: targets, microphone: microphone, epoch: epoch, meeting: observer.snapshot, first: false)
                    do { try await next.start(options: options) }
                    catch {
                        next.lane.finishCapture()
                        next.manifest.stopReason = "startup-error"
                        next.issues.add(String(describing: error))
                        _ = try await next.finish(started: false, failed: true, shutdown: stop.state)
                        throw error
                    }
                    let boundary = counters()
                    assembler.rotate(to: next.lane)
                    let prior = meeting
                    prior.manifest.stopReason = rollover ? "wav-rollover" : "new-meeting"
                    prior.manifest.inputFrames = boundary
                    for (key, initial) in baseline { prior.manifest.inputFrames?[key, default: 0] -= initial }
                    prior.manifest.meeting = observer.snapshot
                    processing = processMeeting(prior, started: true, failed: false, hooks: options.hooks, shutdown: stop.state, after: processing)
                    baseline = boundary
                    meeting = next
                    observer.stop()
                    observer = MeetingObserver(target: primary, title: options.title)
                    meeting.manifest.recording = "recording"
                    try meeting.save()
                    diagnostic("New meeting → \(meeting.directory.path). Processing \(prior.directory.lastPathComponent) in the background.")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            failed = true; reason = "capture-error"
            meeting.issues.add(String(describing: error))
        }

        stop.state.beginDraining()
        if started {
            diagnostic("Stopping capture and saving WAV…")
            meeting.manifest.recording = "stopping"
            do { try meeting.save() } catch { failed = true; meeting.issues.add("Cannot checkpoint stopping capture: \(error)") }
            let stopped = Atomic<Bool>(false)
            let last = meeting
            Task {
                do { try await capture.stop() } catch { last.issues.add("App audio shutdown failed: \(error)") }
                stopped.store(true, ordering: .releasing)
            }
            let deadline = Date().addingTimeInterval(3)
            while !stopped.load(ordering: .acquiring), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            if !stopped.load(ordering: .acquiring) { failed = true; meeting.issues.add("Native audio shutdown timed out") }
        }
        assembler.finishInputs()
        if !assembler.wait() {
            failed = true; meeting.issues.add("Channel assembler shutdown timed out")
            meeting.lane.finishCapture()
        }
        if assembler.failed.load(ordering: .acquiring) { failed = true }
        for issue in engineIssues.all { meeting.issues.add(issue) }
        if started && inputs[1].receivedFrames.load(ordering: .acquiring) == 0 {
            failed = true; meeting.issues.add("No microphone audio was received")
        }
        observer.stop()
        meeting.manifest.meeting = observer.snapshot
        meeting.manifest.inputFrames = frames()
        if reason == "quit" {
            switch stop.received.load(ordering: .acquiring) {
            case SIGINT: reason = "interrupt"
            case SIGTERM: reason = "terminate"
            default: break
            }
        }
        meeting.manifest.stopReason = failed ? "capture-error" : reason
        let result = await processMeeting(meeting, started: started, failed: failed, hooks: options.hooks, shutdown: stop.state, after: processing).value
        keys?.stop()
        for review in result.reviews {
            if try !HookRunner.reviewIfInteractive(session: review.session, run: review.run, options: options.hooks, shutdown: stop.state) { break }
        }
        return result.status
    }

    private static func authorizeAndReport(microphone: InputDevice) async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            diagnostic("macOS will request microphone access for \(microphone.name). Allow access to record.")
        }
    }

    static func finishRecognition(_ workers: [RecognitionWorker], shutdown: ShutdownState) async -> Bool {
        while workers.contains(where: { !$0.isComplete }) {
            if shutdown.interrupted { workers.forEach { $0.cancel() }; return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !workers.contains(where: \.hasFailed) && !shutdown.interrupted
    }

    public static func transcribe(session source: URL, output: URL?, locale: String, hooks: HookOptions = HookOptions()) async throws -> Int32 {
        try hooks.validate()
        var inputSession = source
        var imported = false
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: inputSession.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            let original = inputSession
            let directory: URL
            if let output {
                directory = output
                try privateDirectory(directory)
            } else {
                let parent = CaptureHome(override: hooks.home).recordings
                directory = try CaptureDefaults.reserve(stem: CaptureDefaults.stem(original.deletingPathExtension().lastPathComponent, fallback: "import"), directory: parent)
            }
            let chunk = try SavedAudio.importFile(original, to: directory)
            var manifest = Manifest(app: "imported-audio", microphone: "none", locale: locale)
            manifest.chunks = [chunk]
            manifest.recording = "complete"
            manifest.transcription = "disabled"
            manifest.stopReason = "import"
            try atomicJSON(manifest, at: directory.appendingPathComponent("session.json"))
            diagnostic("Imported audio → \(directory.path)")
            inputSession = directory
            imported = true
        }
        let session = inputSession
        let data = try Data(contentsOf: session.appendingPathComponent("session.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard !manifest.chunks.isEmpty else { throw CaptureError.message("Session contains no saved audio chunks") }
        guard manifest.chunks.count == 1, manifest.chunks[0].source == .recording, (1...3).contains(manifest.chunks[0].channels) else {
            throw CaptureError.message("This session uses the older separate-track format. Create a new three-channel recording; the old files are unchanged.")
        }
        let status = await LocalSpeech.status(locale: locale)
        guard status.ready else { throw CaptureError.message("Local speech unavailable: \(status.assets). No model was downloaded; audio is unchanged.") }
        let directory = imported ? session : (output ?? session.appendingPathComponent("transcripts/\(UUID().uuidString)"))
        if !imported { try privateDirectory(directory) }
        let issues = Issues()
        let tee = try TranscriptTee(directory: directory, issues: issues)
        tee.start()
        let stop = StopSignal()
        var workers: [RecognitionWorker] = []
        let readers = DispatchGroup()
        for source in [Source.recording] {
            let chunks = manifest.chunks.filter { $0.source == source }.sorted { $0.start < $1.start }
            guard !chunks.isEmpty else { continue }
            let lane = AudioLane(source: source, directory: directory, epoch: 0, issues: issues)
            let worker = RecognitionWorker(lane: lane, locale: Locale(identifier: status.locale), tee: tee, issues: issues, realtime: false)
            workers.append(worker)
            do { try await worker.start() }
            catch { worker.cancel(); lane.finishCapture(); issues.add("Speech startup failed: \(error)"); continue }
            readers.enter()
            DispatchQueue(label: "capture-it.replay.\(source.rawValue)", qos: .userInitiated).async {
                defer { lane.finishCapture(); readers.leave() }
                do {
                    for chunk in chunks {
                        guard chunk.file == URL(fileURLWithPath: chunk.file).lastPathComponent else { throw CaptureError.message("Invalid chunk path") }
                        let file = try AVAudioFile(forReading: session.appendingPathComponent(chunk.file))
                        while file.framePosition < file.length, !stop.state.requested, !worker.hasFailed {
                            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw CaptureError.message("Cannot allocate replay buffer") }
                            let time = chunk.start + Double(file.framePosition) / file.processingFormat.sampleRate
                            try file.read(into: buffer)
                            let packet = AudioPacket(buffer: buffer, time: time)
                            while !lane.speech.offer(packet) {
                                if stop.state.requested || worker.hasFailed { return }
                                Thread.sleep(forTimeInterval: 0.005)
                            }
                        }
                    }
                } catch { issues.add("Saved audio replay failed: \(error)"); worker.cancel() }
            }
        }
        let readersDone = Atomic<Bool>(false)
        readers.notify(queue: .global()) { readersDone.store(true, ordering: .releasing) }
        while !readersDone.load(ordering: .acquiring) {
            if stop.state.interrupted { workers.forEach { $0.cancel() } }
            try await Task.sleep(for: .milliseconds(50))
        }
        let stoppedEarly = stop.state.requested
        stop.state.beginDraining()
        diagnostic("Finishing transcription; Ctrl-C to skip waiting.")
        let complete = await finishRecognition(workers, shutdown: stop.state) && !stoppedEarly && issues.all.isEmpty
        try tee.finish(complete: complete, shutdown: stop.state)
        if imported {
            var updated = manifest
            updated.transcription = complete ? "complete" : "incomplete"
            updated.issues = issues.all
            try atomicJSON(updated, at: session.appendingPathComponent("session.json"))
        }
        var hooksComplete = false
        do {
            let run = try await HookRunner.run(session: session, transcriptDirectory: directory, options: hooks, shutdown: stop.state)
            hooksComplete = run.complete
            try HookRunner.reviewIfInteractive(session: session, run: run.speakerRun, options: hooks, shutdown: stop.state)
        }
        catch { issues.add("Post-session hooks failed: \(error)") }
        if imported {
            var updated = manifest
            updated.transcription = complete ? "complete" : "incomplete"
            updated.issues = issues.all
            try atomicJSON(updated, at: session.appendingPathComponent("session.json"))
        }
        for issue in issues.all { diagnostic(issue) }
        diagnostic("Transcript saved to \(directory.path)")
        return complete && hooksComplete && !stop.state.interrupted && !tee.hasFailed && issues.all.isEmpty ? 0 : 2
    }
}
