import Foundation
import XCTest
@testable import CaptureCore

final class MeetingTitleTests: XCTestCase {
    func testDistinctAppWindowTitleIsAnUnverifiedCandidate() {
        let result = MeetingTitlePolicy.choose(titles: ["Microsoft Teams", "Weekly Planning | Microsoft Teams"], appName: "Microsoft Teams")
        XCTAssertEqual(result.title, "Weekly Planning")
        XCTAssertEqual(result.source, "accessibility-window-title")
        XCTAssertEqual(result.status, "candidate")
        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.windowTitle, "Weekly Planning | Microsoft Teams")
    }

    func testGenericAndAmbiguousWindowsAreUnknown() {
        for titles in [[], ["Microsoft Teams"], ["Chat | Microsoft Teams"], ["Calendar — Microsoft Teams"], ["Slack"]] {
            XCTAssertNil(MeetingTitlePolicy.choose(titles: titles, appName: "Microsoft Teams").title)
        }
        let ambiguous = MeetingTitlePolicy.choose(titles: ["One | Microsoft Teams", "Two | Microsoft Teams"], appName: "Microsoft Teams")
        XCTAssertNil(ambiguous.title)
        XCTAssertEqual(ambiguous.status, "ambiguous")
    }

    func testExplicitTitleWinsWithoutNeedingAccessibility() {
        let observer = MeetingObserver(pid: nil, appName: "unknown", title: "  Planning\nReview  ")
        defer { observer.stop() }
        XCTAssertEqual(observer.snapshot.title, "Planning Review")
        XCTAssertEqual(observer.snapshot.source, "explicit")
        XCTAssertTrue(observer.snapshot.verified)
        XCTAssertEqual(observer.snapshot.status, "provided")
    }

    func testWindowTitleSanitizationAndDuplicateCandidates() {
        XCTAssertEqual(MeetingTitlePolicy.clean("Title\u{1B}\n\t  Extra"), "Title Extra")
        XCTAssertEqual(MeetingTitlePolicy.clean(String(repeating: "a", count: 300)).count, 256)
        let result = MeetingTitlePolicy.choose(titles: ["Review | Slack", "Review | Slack"], appName: "Slack")
        XCTAssertEqual(result.title, "Review")
    }
}
