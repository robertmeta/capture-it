import Foundation
import XCTest
@testable import FluidHookSupport

final class SpeakerSuggestionTests: XCTestCase {
    private let run = "A/001"
    private var phrase: AttributedPhrase {
        AttributedPhrase(phrase: TranscriptPhrase(start: 12, duration: 3, text: "Hello, Joe Smith here."),
                         speakers: ["S1"], attribution: "single-speaker-overlap", coverage: 1)
    }

    private func suggestion(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> SpeakerSuggestion {
        var object: [String: Any] = ["version": 1, "id": String(repeating: "a", count: 64), "analysisRun": run,
            "speaker": "S1", "name": "Joe Smith", "confidence": "high", "reason": "Self-introduction",
            "evidence": [["phraseIndex": 0, "start": 12, "end": 15, "quote": "Joe Smith here", "speakers": ["S1"], "attribution": "single-speaker-overlap"]]]
        edit(&object)
        return try JSONDecoder().decode(SpeakerSuggestion.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testExactEvidenceAccepted() throws {
        try suggestion().validate(run: run, phrases: [phrase], speakers: ["S1"])
    }

    func testStaleRunUnknownVoiceAndTerminalControlsRejected() throws {
        XCTAssertThrowsError(try suggestion { $0["name"] = "Made Up" }.validate(run: run, phrases: [phrase], speakers: ["S1"]))
        XCTAssertThrowsError(try suggestion().validate(run: "B/001", phrases: [phrase], speakers: ["S1"]))
        XCTAssertThrowsError(try suggestion().validate(run: run, phrases: [phrase], speakers: ["S2"]))
        XCTAssertThrowsError(try suggestion { $0["name"] = "Joe\u{1B}[2J" }.validate(run: run, phrases: [phrase], speakers: ["S1"]))
    }

    func testChangedQuotesTimingAndMixedEvidenceRejected() throws {
        let changed = AttributedPhrase(phrase: TranscriptPhrase(start: 12, duration: 3, text: "Someone else was mentioned."),
                                       speakers: ["S1"], attribution: "single-speaker-overlap", coverage: 1)
        XCTAssertThrowsError(try suggestion().validate(run: run, phrases: [changed], speakers: ["S1"]))
        let shifted = AttributedPhrase(phrase: TranscriptPhrase(start: 13, duration: 3, text: phrase.phrase.text),
                                       speakers: ["S1"], attribution: "single-speaker-overlap", coverage: 1)
        XCTAssertThrowsError(try suggestion().validate(run: run, phrases: [shifted], speakers: ["S1"]))
        let mixed = AttributedPhrase(phrase: phrase.phrase, speakers: ["S1", "S2"], attribution: "mixed", coverage: 1)
        XCTAssertThrowsError(try suggestion().validate(run: run, phrases: [mixed], speakers: ["S1", "S2"]))
    }
}
