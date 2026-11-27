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
        XCTAssertEqual(voiceExamples(turns, minimumDuration: 0.05)["B"], [10..<10.5])
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

    func testAuditedScoresAndConservativeSampleConsensus() {
        var a = [Float](repeating: 0, count: 256)
        var b = a
        a[0] = 1; b[1] = 1
        let joe = VoiceMatching.assess(a, references: ["Joe": [a], "Alex": [b]])
        let alex = VoiceMatching.assess(b, references: ["Joe": [a], "Alex": [b]])
        let weak = VoiceMatching.assess(b, references: ["Joe": [a]])
        let ambiguous = VoiceMatching.assess(a, references: ["Joe": [a], "Alex": [a]])
        XCTAssertEqual(joe.score, 1)
        XCTAssertEqual(joe.runnerUpScore, 0)
        XCTAssertEqual(ambiguous.reason, "ambiguous")
        XCTAssertEqual(weak.reason, "weak")
        XCTAssertNil(VoiceMatching.consensus([]))
        XCTAssertEqual(VoiceMatching.consensus([joe]), "Joe")
        XCTAssertEqual(VoiceMatching.consensus([joe, joe, weak]), "Joe")
        XCTAssertNil(VoiceMatching.consensus([joe, weak]))
        XCTAssertNil(VoiceMatching.consensus([joe, joe, alex]))
        XCTAssertNil(VoiceMatching.consensus([ambiguous, ambiguous]))
    }
}
