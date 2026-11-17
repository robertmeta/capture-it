import AVFoundation
import Foundation
import Speech
import Synchronization

public struct SpeechStatus: Codable {
    public let available: Bool
    public let locale: String
    public let assets: String
    public let ready: Bool
}

public enum LocalSpeech {
    /// Explicit opt-in command only: downloads language assets from Apple.
    public static func install(locale: String) async throws {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw CaptureError.message("On-device speech does not support this hardware or locale")
        }
        let module = SpeechTranscriber(locale: supported, preset: .transcription)
        guard try await AssetInventory.reserve(locale: supported) else {
            throw CaptureError.message("Cannot reserve speech locale; the system's locale reservation limit was reached")
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard await status(locale: locale).ready else { throw CaptureError.message("Speech assets are not ready after installation") }
    }

    public static func status(locale: String) async -> SpeechStatus {
        guard SpeechTranscriber.isAvailable else { return SpeechStatus(available: false, locale: locale, assets: "unsupported hardware", ready: false) }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            return SpeechStatus(available: true, locale: locale, assets: "unsupported locale", ready: false)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        return SpeechStatus(available: true, locale: supported.identifier, assets: String(describing: status), ready: status == .installed)
    }
}

/// The device-to-speech queue drains on a dedicated worker. Analysis and result
/// consumption use independent asynchronous tasks, with another bounded handoff.
final class RecognitionWorker: @unchecked Sendable {
    private let lane: AudioLane
    private let tee: TranscriptTee
    private let issues: Issues
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let conversionEnded: AsyncStream<Void>
    private let conversionEnd: AsyncStream<Void>.Continuation
    private let realtime: Bool
    private var task: Task<Void, Never>?
    private let conversionDone = DispatchGroup()
    private let completed = Atomic<Bool>(false)
    private let cancelled = Atomic<Bool>(false)
    private let failed = Atomic<Bool>(false)

    init(lane: AudioLane, locale: Locale, tee: TranscriptTee, issues: Issues, realtime: Bool = true) {
        self.lane = lane; self.tee = tee; self.issues = issues
        transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        input = pair.stream; continuation = pair.continuation
        let ending = AsyncStream<Void>.makeStream()
        conversionEnded = ending.stream; conversionEnd = ending.continuation
        self.realtime = realtime
    }

    var isComplete: Bool { completed.load(ordering: .acquiring) }
    var hasFailed: Bool { failed.load(ordering: .acquiring) }

    func start() async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CaptureError.message("No supported on-device speech audio format")
        }
        try await analyzer.prepareToAnalyze(in: format)
        lane.speechEnabled.store(true, ordering: .releasing)
        task = Task.detached { [self] in
            defer { completed.store(true, ordering: .releasing) }
            let results = Task { try await consumeResults() }
            do {
                try await analyzer.start(inputSequence: input)
                for await _ in conversionEnded { }
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                try await results.value
            } catch {
                if !cancelled.load(ordering: .acquiring) { fail("\(lane.source.rawValue) speech recognition failed: \(error)") }
                await analyzer.cancelAndFinishNow()
                results.cancel()
            }
        }
        conversionDone.enter()
        DispatchQueue(label: "capture-it.speech.convert.\(lane.source.rawValue)", qos: .userInitiated).async { [self] in
            defer { continuation.finish(); conversionEnd.finish(); conversionDone.leave() }
            let converter = PCMConverter(output: format)
            var anchor: CMTime?
            var analyzedFrames: Int64 = 0
            let sampleRate = CMTimeScale(format.sampleRate.rounded())
            do {
                while let packet = lane.speech.take() {
                    if cancelled.load(ordering: .acquiring) || hasFailed { continue }
                    if anchor == nil { anchor = CMTime(seconds: packet.time, preferredTimescale: sampleRate) }
                    let speechInput = lane.source == .recording ? try RecordingFormat.mono(packet.buffer) : packet.buffer
                    let buffer = try converter.convert(speechInput)
                    guard buffer.frameLength > 0 else { continue }
                    // Resampled buffer lengths round to whole output frames.
                    // Reusing source timestamps can overlap by one ASR sample,
                    // which SpeechAnalyzer rejects. Use the output sample clock.
                    let time = CMTimeAdd(anchor!, CMTime(value: analyzedFrames, timescale: sampleRate))
                    let value = AnalyzerInput(buffer: buffer, bufferStartTime: time)
                    var delivered = false
                    while !delivered && !hasFailed && !cancelled.load(ordering: .acquiring) {
                        switch continuation.yield(value) {
                        case .enqueued: delivered = true; analyzedFrames += Int64(buffer.frameLength)
                        case .dropped:
                            if realtime { fail("\(lane.source.rawValue) analyzer input queue filled; recording continues") }
                            else { Thread.sleep(forTimeInterval: 0.005) }
                        case .terminated: fail("\(lane.source.rawValue) analyzer input closed early; recording continues")
                        @unknown default: fail("Unknown speech stream state")
                        }
                    }
                }
            } catch { fail("\(lane.source.rawValue) speech conversion failed: \(error)") }
        }
    }

    private func consumeResults() async throws {
        for try await result in transcriber.results {
            if cancelled.load(ordering: .acquiring) { break }
            guard result.isFinal else { continue }
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let segment = Segment(source: lane.source, start: result.range.start.seconds, duration: result.range.duration.seconds, text: text)
            if !tee.emit(segment) { fail("Transcript output unavailable; recording continues"); break }
        }
    }

    private func fail(_ message: String) {
        failed.store(true, ordering: .releasing)
        lane.speechEnabled.store(false, ordering: .releasing)
        issues.add(message)
        continuation.finish()
    }

    func cancel() {
        guard !cancelled.exchange(true, ordering: .acquiringAndReleasing) else { return }
        failed.store(true, ordering: .releasing)
        lane.speechEnabled.store(false, ordering: .releasing)
        continuation.finish()
        task?.cancel()
        if task == nil { completed.store(true, ordering: .releasing) }
        Task { await analyzer.cancelAndFinishNow() }
    }
}
