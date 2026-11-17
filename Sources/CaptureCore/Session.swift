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
    private var sources: [DispatchSourceSignal] = []
    init() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.state.request(count: source.data) }
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
        let resolved = try Hardware.resolveApp(options.app, processID: options.processID)
        if let title = options.title, MeetingTitlePolicy.clean(title).isEmpty { throw CaptureError.message("--title must not be empty") }
        let selectedPID = options.processID ?? resolved.first(where: { $0.bundleID == options.app })?.pid
        let appName = selectedPID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? options.app
        let meeting = MeetingObserver(pid: selectedPID, appName: appName, title: options.title)
        defer { meeting.stop() }
        let micSelection = try Hardware.selectMicrophone(explicitUID: options.microphone, bundle: options.app, processID: options.processID)
        let microphone = micSelection.device
        diagnostic("Microphone: \(microphone.name) (\(micSelection.reason))")
        try privateDirectory(options.output)
        let issues = Issues()
        var manifest = Manifest(app: options.app, microphone: microphone.uid, locale: options.locale)
        manifest.channelLayout = RecordingFormat.channels
        manifest.selectedProcessID = options.processID
        manifest.microphoneSelection = micSelection.source
        manifest.microphoneNote = micSelection.reason
        manifest.meeting = meeting.snapshot
        let manifestURL = options.output.appendingPathComponent("session.json")
        try atomicJSON(manifest, at: manifestURL)
        let epoch = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let inputs = Source.inputs.map { CaptureInput(source: $0, epoch: epoch) }
        let outputLane = AudioLane(source: .recording, directory: options.output, epoch: epoch, issues: issues)
        let lanes = [outputLane]
        let assembler = ChannelAssembler(inputs: inputs, output: outputLane, epoch: epoch, issues: issues)
        var recognizers: [RecognitionWorker] = []
        var tee: TranscriptTee?
        var appCapture: NativeCapture?
        var captureFailed = false
        var warned: Set<String> = []

        do {
            await authorizeAndReport(microphone: microphone)
            try await MicrophoneAccess.authorize()
            if stop.state.requested { throw CaptureError.message("Stopped before recording began") }
            if options.transcribe {
                let status = await LocalSpeech.status(locale: options.locale)
                if status.ready {
                    let output = try TranscriptTee(directory: options.output, issues: issues)
                    output.start(); tee = output
                    for lane in lanes {
                        let worker = RecognitionWorker(lane: lane, locale: Locale(identifier: status.locale), tee: output, issues: issues)
                        recognizers.append(worker)
                        do { try await worker.start() }
                        catch { issues.add("\(lane.source.rawValue) speech startup failed: \(error)"); worker.cancel() }
                    }
                    manifest.transcription = recognizers.contains(where: \.hasFailed) ? "incomplete" : "running"
                } else {
                    manifest.transcription = "unavailable"
                    issues.add("Local speech unavailable for \(options.locale): \(status.assets). Recording audio only; no model was downloaded.")
                }
            } else { manifest.transcription = "disabled" }

            for lane in lanes { lane.startWriter() }
            assembler.start()
            let app = try NativeCapture(bundle: options.app, microphone: microphone, lane: inputs[0], micLane: inputs[1], processID: options.processID); appCapture = app
            diagnostic("Starting selected-app audio capture; allow macOS Screen & System Audio Recording access if prompted")
            try await app.start()
            manifest.recording = "recording"
            try atomicJSON(manifest, at: manifestURL)
            diagnostic("Recording \(options.app) + \(microphone.name) → \(options.output.path)")
            diagnostic("Transcription: \(manifest.transcription). Ctrl-C saves audio and finishes transcription; again skips transcription.")
            if let title = meeting.snapshot.title { diagnostic("Title (\(meeting.snapshot.source ?? "unknown")): \(title)") }
            else if meeting.snapshot.status == "permission-required" { diagnostic("Meeting title unavailable: allow Accessibility with setup-accessibility, or supply --title") }
            let began = Date()
            var lastCheck = Date.distantPast
            while !stop.state.requested {
                if let duration = options.duration, Date().timeIntervalSince(began) >= duration { break }
                if assembler.failed.load(ordering: .acquiring) { throw CaptureError.message("Audio channel assembly failed; recording stopped") }
                for input in inputs where input.overflow.load(ordering: .acquiring) || input.copyFailure.load(ordering: .acquiring) {
                    throw CaptureError.message("\(input.source.rawValue) capture could not preserve every audio buffer; recording stopped")
                }
                for lane in lanes {
                    if lane.recordingOverflow.load(ordering: .acquiring) || lane.copyFailure.load(ordering: .acquiring) {
                        throw CaptureError.message("\(lane.source.rawValue) capture could not persist every audio buffer; recording stopped")
                    }
                    if lane.speechOverflow.load(ordering: .acquiring) {
                        issues.add("\(lane.source.rawValue) speech queue filled; transcript incomplete, audio recording continues")
                        manifest.transcription = "incomplete"
                    }
                }
                if Date().timeIntervalSince(lastCheck) >= 1 {
                    try app.refresh()
                    if recognizers.contains(where: \.hasFailed) || tee?.hasFailed == true { manifest.transcription = "incomplete" }
                    manifest.chunks = lanes.flatMap(\.chunks)
                    manifest.inputFrames = Dictionary(uniqueKeysWithValues: inputs.map { ($0.source.rawValue, $0.receivedFrames.load(ordering: .acquiring)) })
                    manifest.issues = issues.all
                    manifest.meeting = meeting.snapshot
                    try atomicJSON(manifest, at: manifestURL)
                    for issue in manifest.issues where warned.insert(issue).inserted { diagnostic(issue) }
                    lastCheck = Date()
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            captureFailed = true
            issues.add(String(describing: error)); diagnostic(String(describing: error))
        }

        // Stop producers before closing their SPSC queues. WAV closes independently
        // of model finalization, stdout and transcript file drains.
        stop.state.beginDraining()
        diagnostic("Stopping capture and saving WAV…")
        manifest.recording = "stopping"
        manifest.issues = issues.all
        manifest.chunks = lanes.flatMap(\.chunks)
        try atomicJSON(manifest, at: manifestURL)
        let stopped = Atomic<Int>(0)
        let stoppingApp = appCapture
        Task {
            do { try await stoppingApp?.stop() }
            catch { issues.add("App audio shutdown failed: \(error)") }
            stopped.add(1, ordering: .releasing)
        }
        let stopDeadline = Date().addingTimeInterval(3)
        while stopped.load(ordering: .acquiring) < 1, Date() < stopDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        if stopped.load(ordering: .acquiring) < 1 {
            captureFailed = true; issues.add("Native audio shutdown timed out; audio files will be closed and the process will exit")
        }
        assembler.finishInputs()
        if !assembler.wait() {
            captureFailed = true; issues.add("Channel assembler shutdown timed out")
            outputLane.finishCapture()
        }
        if assembler.failed.load(ordering: .acquiring) { captureFailed = true }
        for lane in lanes {
            if !lane.waitForWriter() { captureFailed = true; issues.add("\(lane.source.rawValue) WAV writer shutdown timed out") }
            if lane.recordingOverflow.load(ordering: .acquiring) { captureFailed = true }
        }
        manifest.chunks = lanes.flatMap(\.chunks)
        if manifest.chunks.isEmpty || manifest.chunks.contains(where: { !$0.closed }) {
            captureFailed = true; issues.add("Recording did not produce complete audio tracks")
        }
        manifest.inputFrames = Dictionary(uniqueKeysWithValues: inputs.map { ($0.source.rawValue, $0.receivedFrames.load(ordering: .acquiring)) })
        for input in inputs where input.receivedFrames.load(ordering: .acquiring) == 0 {
            captureFailed = true; issues.add("No \(input.source.rawValue) audio was received")
        }
        manifest.recording = captureFailed ? "failed" : "complete"
        meeting.stop()
        manifest.meeting = meeting.snapshot
        manifest.issues = issues.all
        try atomicJSON(manifest, at: manifestURL) // audio completion survives a speech shutdown failure

        if tee != nil {
            let audioStatus = captureFailed ? "Audio shutdown finished with issues." : "WAV saved."
            diagnostic("\(audioStatus) Finishing transcription; Ctrl-C again to skip waiting.")
        }
        let finalized = await finishRecognition(recognizers, shutdown: stop.state)
        if manifest.transcription == "running" { manifest.transcription = finalized ? "complete" : "incomplete" }
        if lanes.contains(where: { $0.speechOverflow.load(ordering: .acquiring) }) { manifest.transcription = "incomplete" }
        if let tee {
            do { try tee.finish(complete: manifest.transcription == "complete", shutdown: stop.state) }
            catch { manifest.transcription = "incomplete"; issues.add(String(describing: error)) }
            if tee.hasFailed { manifest.transcription = "incomplete" }
        }
        if stop.state.interrupted, tee != nil {
            recognizers.forEach { $0.cancel() }
            manifest.transcription = "interrupted"
            issues.add("Transcription interrupted by user; saved WAV and written transcript retained")
        }
        manifest.issues = issues.all
        try atomicJSON(manifest, at: manifestURL)
        do {
            if !(try await HookRunner.run(session: options.output, options: options.hooks, shutdown: stop.state)) {
                issues.add("Post-session hooks did not all complete; see the session's hooks directory")
            }
        } catch { issues.add("Post-session hooks failed: \(error)") }
        manifest.issues = issues.all
        try atomicJSON(manifest, at: manifestURL)
        for issue in manifest.issues where warned.insert(issue).inserted { diagnostic(issue) }
        diagnostic("Saved \(options.output.path); audio \(manifest.recording), transcript \(manifest.transcription)")
        return captureFailed ? 1 : (manifest.issues.isEmpty ? 0 : 2)
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

    public static func transcribe(session: URL, output: URL?, locale: String, hooks: HookOptions = HookOptions()) async throws -> Int32 {
        try hooks.validate()
        let data = try Data(contentsOf: session.appendingPathComponent("session.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard !manifest.chunks.isEmpty else { throw CaptureError.message("Session contains no saved audio chunks") }
        guard manifest.chunks.count == 1, manifest.chunks[0].source == .recording, manifest.chunks[0].channels == 3 else {
            throw CaptureError.message("This session uses the older separate-track format. Create a new three-channel recording; the old files are unchanged.")
        }
        let status = await LocalSpeech.status(locale: locale)
        guard status.ready else { throw CaptureError.message("Local speech unavailable: \(status.assets). No model was downloaded; audio is unchanged.") }
        let directory = output ?? session.appendingPathComponent("transcripts/\(UUID().uuidString)")
        try privateDirectory(directory)
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
        var hooksComplete = false
        do { hooksComplete = try await HookRunner.run(session: session, transcriptDirectory: directory, options: hooks, shutdown: stop.state) }
        catch { issues.add("Post-session hooks failed: \(error)") }
        for issue in issues.all { diagnostic(issue) }
        diagnostic("Transcript saved to \(directory.path)")
        return complete && hooksComplete && !stop.state.interrupted && !tee.hasFailed && issues.all.isEmpty ? 0 : 2
    }
}
