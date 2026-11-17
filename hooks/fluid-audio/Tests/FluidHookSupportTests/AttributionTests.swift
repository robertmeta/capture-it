import AVFoundation
import Foundation
import XCTest
@testable import FluidHookSupport

final class AttributionTests: XCTestCase {
    func testMixedPhraseIsNotAssignedToTheLouderOrLongerSpeaker() throws {
        let turns = [SpeakerTurn(start: 0, end: 4, speaker: "speaker-1"), SpeakerTurn(start: 4, end: 5, speaker: "speaker-2")]
        let phrase = TranscriptPhrase(start: 0, duration: 5, text: "Original words remain together")
        let labeled = try PhraseAttribution.attribute(phrase, turns: turns)
        XCTAssertEqual(labeled.attribution, "mixed")
        XCTAssertEqual(labeled.speakers, ["speaker-1", "speaker-2"])
        XCTAssertEqual(labeled.phrase.text, phrase.text)
        XCTAssertTrue(PhraseAttribution.line(labeled).contains("[mixed: speaker-1, speaker-2]"))
    }

    func testUnknownAndBoundaryAttribution() throws {
        let turns = [SpeakerTurn(start: 1, end: 3, speaker: "speaker-1"), SpeakerTurn(start: 3, end: 4, speaker: "speaker-2")]
        XCTAssertEqual(try PhraseAttribution.attribute(TranscriptPhrase(start: 1, duration: 2, text: "one"), turns: turns).attribution, "single-speaker-overlap")
        XCTAssertEqual(try PhraseAttribution.attribute(TranscriptPhrase(start: 8, duration: 1, text: "none"), turns: turns).attribution, "unknown")
        XCTAssertEqual(try PhraseAttribution.attribute(TranscriptPhrase(start: 0, duration: 10, text: "uncertain"), turns: [turns[0]]).attribution, "unknown")
        XCTAssertThrowsError(try PhraseAttribution.attribute(TranscriptPhrase(start: -1, duration: 1, text: "bad"), turns: turns))
        XCTAssertThrowsError(try PhraseAttribution.attribute(TranscriptPhrase(start: 1e100, duration: 1, text: "too large"), turns: turns))
    }

    func testSimultaneousVoicesDoNotDoubleCountCoverage() throws {
        let turns = [SpeakerTurn(start: 0, end: 2, speaker: "a"), SpeakerTurn(start: 0, end: 2, speaker: "b")]
        let result = try PhraseAttribution.attribute(TranscriptPhrase(start: 0, duration: 4, text: "overlap"), turns: turns)
        XCTAssertEqual(result.coverage, 0.5)
        XCTAssertEqual(result.attribution, "mixed")
    }

    func testAnalysisMixIncludesMicAndPreservesDuration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fluid-support-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let target = directory.appendingPathComponent("analysis.wav")
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        buffer.floatChannelData![0].update(repeating: 0, count: 48_000)
        buffer.floatChannelData![1].update(repeating: 0, count: 48_000)
        buffer.floatChannelData![2].update(repeating: 0.5, count: 48_000)
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        XCTAssertEqual(try AnalysisAudio.prepare(wav: source, destination: target), 1, accuracy: 0.0001)
        let file = try AVAudioFile(forReading: target)
        XCTAssertEqual(file.processingFormat.sampleRate, 16000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / 16000, 1, accuracy: 0.002)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000)!
        try file.read(into: read)
        XCTAssertEqual(read.floatChannelData![0][8000], 0.25, accuracy: 0.001)
    }
}
