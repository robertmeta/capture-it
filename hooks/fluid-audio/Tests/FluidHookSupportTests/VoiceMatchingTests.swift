import XCTest
@testable import FluidHookSupport

final class VoiceMatchingTests: XCTestCase {
    func testExamplesExcludeOtherVoicesAndCombineOverlappingTurnsFromOneSpeaker() {
        let turns = [
            SpeakerTurn(start: 0, end: 10, speaker: "A"),
            SpeakerTurn(start: 1, end: 8, speaker: "A"),
            SpeakerTurn(start: 2, end: 5, speaker: "B"),
            SpeakerTurn(start: 10, end: 10.5, speaker: "B"),
            SpeakerTurn(start: 20, end: 40, speaker: "A")
        ]
        let spans = voiceExamples(turns)
        XCTAssertEqual(spans["A"], [26..<34, 5..<10, 0..<2])
        XCTAssertTrue((spans["B"] ?? []).isEmpty)
    }

    func testWeakAmbiguousAndIncompatibleVoicesStayAnonymous() {
        var a = [Float](repeating: 0, count: 256)
        var b = a
        a[0] = 1
        b[1] = 1
        XCTAssertNil(VoiceMatching.match(a, references: ["Joe": [b]]))
        XCTAssertNil(VoiceMatching.match(a, references: ["Joe": [a], "Alex": [a]]))
        XCTAssertNil(VoiceMatching.match([], references: ["Joe": [a]]))
        XCTAssertEqual(VoiceMatching.match(a, references: ["Joe": [a, b]]), "Joe")
    }
}
