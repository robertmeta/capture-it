import Foundation
import XCTest
@testable import CaptureCore

final class CaptureDefaultsTests: XCTestCase {
    let devices = [
        InputDevice(id: 1, uid: "default", name: "System Mic", isDefault: true),
        InputDevice(id: 2, uid: "teams", name: "App Mic", isDefault: false)
    ]

    func testExplicitMicrophoneWinsEvenWhenAppUsesAnotherInput() throws {
        let chosen = try MicrophonePolicy.choose(explicitUID: "default", devices: devices, activeAppDevices: [2], canCapture: { _ in true })
        XCTAssertEqual(chosen.device.uid, "default")
        XCTAssertEqual(chosen.source, "explicit")
        XCTAssertThrowsError(try MicrophonePolicy.choose(explicitUID: "missing", devices: devices, activeAppDevices: [2], canCapture: { _ in true }))
    }

    func testUniqueActiveAppInputOverridesDifferentSystemDefault() throws {
        let chosen = try MicrophonePolicy.choose(explicitUID: nil, devices: devices, activeAppDevices: [2], canCapture: { _ in true })
        XCTAssertEqual(chosen.device.uid, "teams")
        XCTAssertEqual(chosen.source, "app")
    }

    func testUnknownInactiveAmbiguousAndUncapturableInputsUseDefault() throws {
        for ids: Set<UInt32>? in [nil, [], [1, 2], [99], [2, 99]] {
            let chosen = try MicrophonePolicy.choose(explicitUID: nil, devices: devices, activeAppDevices: ids, canCapture: { _ in true })
            XCTAssertEqual(chosen.device.uid, "default")
            XCTAssertEqual(chosen.source, "system-default")
        }
        let unsupported = try MicrophonePolicy.choose(explicitUID: nil, devices: devices, activeAppDevices: [2], canCapture: { _ in false })
        XCTAssertEqual(unsupported.source, "system-default")
        XCTAssertThrowsError(try MicrophonePolicy.choose(explicitUID: nil, devices: [], activeAppDevices: [], canCapture: { _ in true }))
    }

    func testQueryStemRemovesWildcardsAndPathCharacters() {
        XCTAssertEqual(CaptureDefaults.stem("*Teams*", fallback: "Microsoft Teams"), "teams")
        XCTAssertEqual(CaptureDefaults.stem("Microsoft Teams", fallback: "other"), "microsoft-teams")
        XCTAssertEqual(CaptureDefaults.stem("../Teams/../../call", fallback: "other"), "teams-..-..-call")
        XCTAssertEqual(CaptureDefaults.stem("*??*", fallback: "Microsoft Teams"), "microsoft-teams")
    }

    func testDefaultOutputIsLocalDatedAndAvoidsExistingDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("capture-it-default-\(UUID())")
        try privateDirectory(parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = CaptureDefaults.output(query: "*Teams*", appName: "Microsoft Teams", directory: parent, date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(first.deletingLastPathComponent().path, parent.path)
        XCTAssertEqual(first.lastPathComponent, "teams-19700101-000000")
        try privateDirectory(first)
        let next = CaptureDefaults.output(query: "*Teams*", appName: "Microsoft Teams", directory: parent, date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(next.lastPathComponent, "teams-19700101-000000-2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }
}
