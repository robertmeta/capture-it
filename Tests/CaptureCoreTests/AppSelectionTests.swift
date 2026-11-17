import XCTest
@testable import CaptureCore

final class AppSelectionTests: XCTestCase {
    private let apps = [
        AppChoice(name: "Microsoft Teams", bundleID: "com.microsoft.teams2", pid: 10),
        AppChoice(name: "Teams Preview", bundleID: "com.example.teams-preview", pid: 20),
        AppChoice(name: "Safari", bundleID: "com.apple.Safari", pid: 30)
    ]

    func testNamesAndBundleSubstringsAreCaseInsensitive() throws {
        XCTAssertEqual(try AppSelection.matches("  TEAMS  ", in: apps).map(\.pid), [10, 20])
        XCTAssertEqual(try AppSelection.matches("microsoft", in: apps).map(\.pid), [10])
        XCTAssertEqual(try AppSelection.matches("apple.saf", in: apps).map(\.pid), [30])
    }

    func testWildcardMatchingAndExactBundlePriority() throws {
        XCTAssertEqual(try AppSelection.matches("*team?*", in: apps).map(\.pid), [10, 20])
        XCTAssertEqual(try AppSelection.matches("Microsoft *", in: apps).map(\.pid), [10])
        let extended = apps + [AppChoice(name: "Other Teams", bundleID: "com.microsoft.teams2.preview", pid: 40)]
        XCTAssertEqual(try AppSelection.matches("COM.MICROSOFT.TEAMS2", in: extended).map(\.pid), [10])
        XCTAssertTrue(try AppSelection.matches("[teams]", in: apps).isEmpty) // literal, not regex
    }

    func testSingleMatchAutoSelectsWithoutReadingInput() throws {
        let selected = try AppSelection.choose("safari", from: apps, interactive: false,
            read: { XCTFail("Unique match must not prompt"); return nil }, write: { _ in })
        XCTAssertEqual(selected.pid, 30)
    }

    func testPickerRetriesInvalidInputAndSelectsNumber() throws {
        var answers = ["zero", "0", "3", "2"]
        var output = ""
        let selected = try AppSelection.choose("teams", from: apps, interactive: true,
            read: { answers.removeFirst() }, write: { output += $0 })
        XCTAssertEqual(selected.pid, 20)
        XCTAssertTrue(output.contains("1. Microsoft Teams"))
        XCTAssertTrue(output.contains("2. Teams Preview"))
        XCTAssertTrue(output.contains("Enter a number"))
    }

    func testCancellationEOFAndNoninteractiveAmbiguityFail() {
        for answer: String? in ["q", "Q", nil] {
            XCTAssertThrowsError(try AppSelection.choose("teams", from: apps, interactive: true, read: { answer }, write: { _ in }))
        }
        XCTAssertThrowsError(try AppSelection.choose("teams", from: apps, interactive: false,
            read: { XCTFail("Noninteractive picker must not read"); return nil }, write: { _ in }))
        XCTAssertThrowsError(try AppSelection.matches(" ", in: apps))
        XCTAssertThrowsError(try AppSelection.choose("missing", from: apps, interactive: true,
            read: { XCTFail("No-match picker must not read"); return nil }, write: { _ in }))
    }

    func testSameBundleInstancesRemainSeparatePIDChoices() throws {
        let same = [apps[0], AppChoice(name: "Microsoft Teams", bundleID: apps[0].bundleID, pid: 11)]
        XCTAssertEqual(try AppSelection.matches("com.microsoft.teams2", in: same).map(\.pid), [10, 11])
    }
}
