import AVFoundation
import Foundation

/// A meeting is owned by the capture loop until its lane is detached. One background
/// task then owns its manifest and finalizes the WAV, transcript and hooks in order.
final class MeetingRecording: @unchecked Sendable {
    let directory: URL
    let lane: AudioLane
    let issues = Issues()
    var manifest: Manifest
    private var recognizers: [RecognitionWorker] = []
    private var tee: TranscriptTee?
    private let container: RecordingContainer
    private var warned: Set<String> = []

    init(options: RecordOptions, targets: [AppChoice], microphone: MicrophoneChoice, epoch: Double,
         meeting: MeetingMetadata, first: Bool) throws {
        container = options.container
        let numbered = options.numberFirstMeeting || !first
        if numbered {
            let parent = options.numberFirstMeeting ? options.output : options.output.deletingLastPathComponent()
            directory = try CaptureDefaults.reserve(stem: options.meetingStem ?? CaptureDefaults.stem(options.app, fallback: "capture"), directory: parent)
        } else {
            directory = options.output
            try privateDirectory(directory)
        }
        lane = AudioLane(source: .recording, directory: directory, epoch: epoch, issues: issues,
                         file: numbered ? directory.lastPathComponent + ".wav" : "recording.wav")
        manifest = Manifest(app: options.app, microphone: microphone.device.uid, locale: options.locale)
        manifest.apps = targets.map(\.bundleID)
        if targets.count == 1, let pid = targets.first?.pid, pid > 0 { manifest.selectedProcessID = pid }
        manifest.channelLayout = RecordingFormat.channels
        manifest.microphoneSelection = microphone.source
        manifest.microphoneNote = microphone.reason
        manifest.meeting = meeting
        if !options.transcribe { manifest.transcription = "disabled" }
        try save()
    }

    func start(options: RecordOptions) async throws {
        if options.transcribe {
            let status = await LocalSpeech.status(locale: options.locale)
            if status.ready {
                let output = try TranscriptTee(directory: directory, issues: issues)
                output.start(); tee = output
                let worker = RecognitionWorker(lane: lane, locale: Locale(identifier: status.locale), tee: output, issues: issues)
                recognizers.append(worker)
                do { try await worker.start(); manifest.transcription = "running" }
                catch {
                    issues.add("recording speech startup failed: \(error)")
                    worker.cancel(); manifest.transcription = "incomplete"
                }
            } else {
                manifest.transcription = "unavailable"
                issues.add("Local speech unavailable for \(options.locale): \(status.assets). Recording audio only; no model was downloaded.")
            }
        }
        lane.startWriter()
    }

    func checkpoint(meeting: MeetingMetadata, frames: [String: Int64]) throws {
        if lane.speechOverflow.load(ordering: .acquiring) {
            issues.add("recording speech queue filled; transcript incomplete, audio recording continues")
            manifest.transcription = "incomplete"
        }
        if recognizers.contains(where: \.hasFailed) || tee?.hasFailed == true { manifest.transcription = "incomplete" }
        manifest.inputFrames = frames
        manifest.meeting = meeting
        manifest.chunks = lane.chunks
        try save()
    }

    func save() throws {
        manifest.issues = issues.all
        try atomicJSON(manifest, at: directory.appendingPathComponent("session.json"))
        for issue in manifest.issues where warned.insert(issue).inserted { diagnostic(issue) }
    }

    func finish(started: Bool, failed: Bool, shutdown: ShutdownState) async throws -> Bool {
        var audioFailed = failed
        if !lane.waitForWriter() { audioFailed = true; issues.add("recording WAV writer shutdown timed out") }
        if lane.recordingOverflow.load(ordering: .acquiring) { audioFailed = true }
        manifest.chunks = lane.chunks
        if started && (manifest.chunks.isEmpty || manifest.chunks.contains(where: { !$0.closed })) {
            audioFailed = true; issues.add("Recording did not produce complete audio tracks")
        }
        manifest.recording = audioFailed ? "failed" : "complete"
        if !started && ["starting", "running"].contains(manifest.transcription) { manifest.transcription = "incomplete" }
        try save()
        if !audioFailed, started, container == .m4a, let original = manifest.chunks.first {
            do {
                diagnostic("Saving M4A for \(directory.lastPathComponent)…")
                let encoded = try SavedAudio.finalize(original, in: directory)
                manifest.chunks = [encoded]
                try save()
                do { try FileManager.default.removeItem(at: directory.appendingPathComponent(original.file)) }
                catch { issues.add("M4A saved; recovery WAV could not be removed: \(error)") }
            } catch {
                audioFailed = true
                manifest.chunks = [original]
                manifest.recording = "failed"
                issues.add("M4A finalization failed; recovery WAV retained: \(error)")
                try save()
            }
        }
        if tee != nil && started {
            diagnostic("\(audioFailed ? "Audio shutdown finished with issues." : "Audio saved.") Finishing transcription for \(directory.lastPathComponent).")
        }
        let finalized = await Sessions.finishRecognition(recognizers, shutdown: shutdown)
        if manifest.transcription == "running" { manifest.transcription = finalized ? "complete" : "incomplete" }
        if lane.speechOverflow.load(ordering: .acquiring) { manifest.transcription = "incomplete" }
        if let tee {
            do { try tee.finish(complete: manifest.transcription == "complete", shutdown: shutdown) }
            catch { manifest.transcription = "incomplete"; issues.add(String(describing: error)) }
            if tee.hasFailed { manifest.transcription = "incomplete" }
            if shutdown.interrupted {
                manifest.transcription = "interrupted"
                issues.add("Transcription interrupted by user; saved WAV and written transcript retained")
            }
        }
        recognizers.removeAll()
        tee = nil
        try save()
        return !audioFailed
    }
}

struct ProcessedMeeting: Sendable {
    var status: Int32
    var reviews: [(session: URL, run: String)]
}

/// Close each meeting immediately. Chain only the resource-intensive analysis, so
/// multiple presses of n cannot launch competing FluidAudio jobs or interrupt capture.
func processMeeting(_ meeting: MeetingRecording, started: Bool, failed: Bool, hooks: HookOptions,
                    shutdown: ShutdownState, after previous: Task<ProcessedMeeting, Never>?) -> Task<ProcessedMeeting, Never> {
    Task {
        var status: Int32 = 0
        var run: String?
        var finalized = false
        do {
            if try await !meeting.finish(started: started, failed: failed, shutdown: shutdown) { status = 1 }
            finalized = true
        } catch { status = 1; diagnostic("Could not finalize \(meeting.directory.path): \(error)") }
        var result = await previous?.value ?? ProcessedMeeting(status: 0, reviews: [])
        if started && finalized {
            do {
                let result = try await HookRunner.run(session: meeting.directory, options: hooks, shutdown: shutdown)
                run = result.speakerRun
                if !result.complete { meeting.issues.add("Post-session hooks did not all complete; see the session's hooks directory") }
            } catch { meeting.issues.add("Post-session hooks failed: \(error)") }
            do { try meeting.save() } catch { status = 1; diagnostic("Cannot save meeting manifest: \(error)") }
        }
        if !started { diagnostic("Recording did not start. Failure details saved to \(meeting.directory.path)/session.json") }
        else { diagnostic("Saved \(meeting.directory.path); audio \(meeting.manifest.recording), transcript \(meeting.manifest.transcription)") }
        if status == 0 && !meeting.issues.all.isEmpty { status = 2 }
        if let run, hooks.promptForSpeakers { result.reviews.append((meeting.directory, run)) }
        result.status = status == 1 || result.status == 1 ? 1 : max(status, result.status)
        return result
    }
}
