import CapturePaths
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

    func testCaptureHomeKeepsExistingEnrollmentsAndRespectsExplicitLocations() throws {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: user) }
        let defaults = CaptureHome(environment: [:], userDirectory: user)
        XCTAssertEqual(defaults.recordings.path, user.appendingPathComponent("Documents/capture-it/recordings").path)
        XCTAssertEqual(defaults.voices.path, user.appendingPathComponent("Documents/capture-it/voices").path)
        let previous = user.appendingPathComponent("Library/Application Support/capture-it/voices")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        XCTAssertEqual(CaptureHome(environment: [:], userDirectory: user).voices.path, previous.path)
        let selected = user.appendingPathComponent("other")
        let override = CaptureHome(override: selected, environment: ["CAPTURE_IT_HOME": "/ignored"], userDirectory: user)
        XCTAssertEqual(override.voices.path, selected.appendingPathComponent("voices").path)
        XCTAssertEqual(CaptureHome(override: selected, environment: ["CAPTURE_IT_VOICES": previous.path]).voices.path, previous.path)
    }

    func testRolloverBeforeRIFFLimit() {
        let boundary: Int64 = 4 * 3600 * 48000
        XCTAssertFalse(CaptureDefaults.needsRollover(frames: boundary - 1))
        XCTAssertTrue(CaptureDefaults.needsRollover(frames: boundary))
    }

    func testDefaultOutputIsLocalDatedAndAvoidsExistingDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("capture-it-default-\(UUID())")
        try privateDirectory(parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try CaptureDefaults.reserve(stem: "teams", directory: parent, date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(first.deletingLastPathComponent().path, parent.path)
        XCTAssertEqual(first.lastPathComponent, "teams-1970-01-01-01")
        let next = try CaptureDefaults.reserve(stem: "teams", directory: parent, date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(next.lastPathComponent, "teams-1970-01-01-02")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        try privateDirectory(parent.appendingPathComponent("teams-1970-01-01-99"))
        let hundredth = try CaptureDefaults.reserve(stem: "teams", directory: parent, date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(hundredth.lastPathComponent, "teams-1970-01-01-100")
        let local = try CaptureDefaults.reserve(stem: "teams", directory: parent, date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: -18000)!)
        XCTAssertEqual(local.lastPathComponent, "teams-1969-12-31-01")
    }
}
