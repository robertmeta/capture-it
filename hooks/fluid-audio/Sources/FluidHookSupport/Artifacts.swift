import AVFoundation
import Foundation

/// An actionable hook failure, also usable by model-free validation tests.
public struct HookFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The stable portion of capture-it's versioned post-session handoff.
public struct FluidInput: Decodable {
    public let version: Int
    public let event: String
    public let wav: String
    public let segments: String?
    public let transcriptComplete: Bool?

    /// Load only a supported capture-it event with a saved source file.
    public static func load(_ url: URL) throws -> FluidInput {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1, value.event == "session-finished", value.wav.hasPrefix("/"),
              FileManager.default.fileExists(atPath: value.wav) else {
            throw HookFailure("Expected a version-1 session-finished event with an absolute WAV path")
        }
        return value
    }
}

/// Anonymous speaker interval measured in seconds from recording start.
public struct SpeakerTurn: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public init(start: Double, end: Double, speaker: String) {
        self.start = start; self.end = end; self.speaker = speaker
    }

    /// Intersect padded model windows with the source audio before exporting turns.
    /// A turn entirely in model padding has no source samples and is omitted.
    public func clipped(to duration: Double) throws -> SpeakerTurn? {
        guard duration.isFinite, duration >= 0, start.isFinite, end.isFinite, end >= start else {
            throw HookFailure("Diarizer returned an invalid time range: start=\(start), end=\(end), sourceDuration=\(duration)")
        }
        let first = max(0, start)
        let last = min(end, duration)
        guard last > first else { return nil }
        return SpeakerTurn(start: first, end: last, speaker: speaker)
    }
}

/// Original phrase data; timing and text are retained without guessing word boundaries.
public struct TranscriptPhrase: Codable, Sendable {
    public let source: String?
    public let start: Double
    public let duration: Double
    public let text: String
    public init(start: Double, duration: Double, text: String, source: String? = "recording") {
        self.source = source; self.start = start; self.duration = duration; self.text = text
    }
}

/// A derived label plus the untouched source phrase and overlap evidence.
public struct AttributedPhrase: Codable {
    public let phrase: TranscriptPhrase
    public let speakers: [String]
    public let attribution: String
    public let coverage: Double
}

/// Conservative phrase attribution. Multiple intersecting voices stay mixed.
public enum PhraseAttribution {
    public static func attribute(_ phrase: TranscriptPhrase, turns: [SpeakerTurn]) throws -> AttributedPhrase {
        guard phrase.start.isFinite, phrase.start >= 0, phrase.duration.isFinite, phrase.duration >= 0 else {
            throw HookFailure("Transcript contains an invalid phrase time")
        }
        let end = phrase.start + phrase.duration
        guard end.isFinite, phrase.start < Double(Int.max) else { throw HookFailure("Transcript phrase time is out of range") }
        let overlaps = turns.compactMap { turn -> (String, Double, Double)? in
            let begin = max(phrase.start, turn.start)
            let finish = min(end, turn.end)
            return finish > begin ? (turn.speaker, begin, finish) : nil
        }
        let speakers = Array(Set(overlaps.map(\.0))).sorted()
        // Union the intervals: simultaneous speakers must not inflate coverage.
        var covered = 0.0
        var previousEnd = phrase.start
        for (_, begin, finish) in overlaps.sorted(by: { $0.1 < $1.1 }) {
            covered += max(0, finish - max(begin, previousEnd))
            previousEnd = max(previousEnd, finish)
        }
        let coverage = phrase.duration > 0 ? min(1, covered / phrase.duration) : 0
        let attribution = speakers.count > 1 ? "mixed" : (speakers.count == 1 && coverage >= 0.5 ? "single-speaker-overlap" : "unknown")
        return AttributedPhrase(phrase: phrase, speakers: speakers, attribution: attribution, coverage: coverage)
    }

    /// Build a derived text copy. Input transcript files are never modified.
    public static func line(_ value: AttributedPhrase, names: [String: String] = [:]) -> String {
        let stamp = timestamp(value.phrase.start)
        let speakers = value.speakers.map { names[$0] ?? $0 }
        let label = value.attribution == "single-speaker-overlap" ? speakers.first ?? "unknown"
            : (value.attribution == "mixed" ? "mixed: " + speakers.joined(separator: ", ") : "unknown")
        return "[\(stamp)] [\(label)] \(value.phrase.text.replacingOccurrences(of: "\n", with: " "))\n"
    }

    private static func timestamp(_ time: Double) -> String {
        String(format: "%02d:%02d:%06.3f", Int(time) / 3600, (Int(time) / 60) % 60, time.truncatingRemainder(dividingBy: 60))
    }
}

/// Prepare the same .25 L + .25 R + .5 mic mix at 16 kHz using bounded buffers.
public enum AnalysisAudio {
    @discardableResult public static func prepare(wav: URL, destination: URL, interval: Range<Double>? = nil) throws -> Double {
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard (1...3).contains(file.processingFormat.channelCount) else {
            throw HookFailure("FluidAudio hook expects one, two or three audio channels")
        }
        let rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        let span = interval ?? 0..<duration
        guard span.lowerBound >= 0, span.upperBound <= duration else { throw HookFailure("Speaker interval exceeds source audio") }
        file.framePosition = AVAudioFramePosition(ceil(span.lowerBound * rate))
        let endFrame = interval == nil ? file.length : min(file.length, AVAudioFramePosition(floor(span.upperBound * rate)))
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let converter = AVAudioConverter(from: mono, to: outputFormat) else { throw HookFailure("Cannot create audio resampler") }
        converter.primeMethod = .none
        let output = try AVAudioFile(forWriting: destination, settings: outputFormat.settings)
        let incoming = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8190)!
        let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 8190)!
        let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(8190 * 16_000 / rate)) + 256)!
        while file.framePosition < endFrame {
            let frames = AVAudioFrameCount(min(Int64(incoming.frameCapacity), endFrame - file.framePosition))
            try file.read(into: incoming, frameCount: frames)
            guard incoming.frameLength > 0 else { throw HookFailure("Unexpected end of source audio") }
            mixed.frameLength = incoming.frameLength
            let channels = incoming.floatChannelData!
            for index in 0 ..< Int(incoming.frameLength) {
                switch file.processingFormat.channelCount {
                case 1: mixed.floatChannelData![0][index] = channels[0][index]
                case 2: mixed.floatChannelData![0][index] = 0.5 * channels[0][index] + 0.5 * channels[1][index]
                default: mixed.floatChannelData![0][index] = 0.25 * channels[0][index] + 0.25 * channels[1][index] + 0.5 * channels[2][index]
                }
            }
            var supplied = false
            var error: NSError?
            let result = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return mixed
            }
            if result == .error { throw error ?? HookFailure("Audio resampling failed") as NSError }
            if converted.frameLength > 0 { try output.write(from: converted) }
        }
        // Flush the converter's tail so analysis duration stays aligned to the WAV.
        while true {
            var error: NSError?
            let result = converter.convert(to: converted, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            if result == .error { throw error ?? HookFailure("Audio resampling flush failed") as NSError }
            if converted.frameLength > 0 { try output.write(from: converted) }
            if result == .endOfStream || converted.frameLength == 0 { break }
        }
        return span.upperBound - span.lowerBound
    }
}

/// Create a derived private artifact without overwriting an existing run's data.
public func writeArtifact(_ data: Data, to url: URL) throws {
    let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard descriptor >= 0 else { throw HookFailure("Cannot create new artifact \(url.path): \(String(cString: strerror(errno)))") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
}

/// Encode a deterministic JSON artifact with private permissions.
public func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try writeArtifact(encoder.encode(value), to: url)
}
