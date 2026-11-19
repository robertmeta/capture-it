import Darwin
import Foundation
import XCTest
@testable import CaptureCore

final class ShutdownTests: XCTestCase {
    func testFirstInterruptDrainsAndSecondInterruptSkips() {
        let state = ShutdownState()
        XCTAssertFalse(state.requested)
        state.request()
        XCTAssertTrue(state.requested)
        XCTAssertFalse(state.interrupted)
        state.beginDraining()
        XCTAssertFalse(state.interrupted)
        state.request()
        XCTAssertTrue(state.interrupted)
    }

    func testCoalescedSignalsAndAutomaticStop() {
        let coalesced = ShutdownState()
        coalesced.request(count: 2)
        XCTAssertTrue(coalesced.interrupted)
        let automatic = ShutdownState()
        automatic.beginDraining()
        XCTAssertFalse(automatic.interrupted)
        automatic.request()
        XCTAssertTrue(automatic.interrupted)
    }

    func testRepeatedGracefulKeyDoesNotEscalateAndSignalsStillCan() {
        let state = ShutdownState()
        for _ in 0 ..< 10 { state.beginDraining() }
        XCTAssertTrue(state.requested)
        XCTAssertFalse(state.interrupted)
        state.request()
        XCTAssertTrue(state.interrupted)
        state.beginDraining()
        XCTAssertTrue(state.interrupted)
    }

    func testInterruptWhileStdoutIsBlockedRetainsTextAndIncompleteSummary() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("capture-it-shutdown-\(UUID())")
        try privateDirectory(path)
        defer { try? FileManager.default.removeItem(at: path) }
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let original = fcntl(descriptors[1], F_GETFL)
        XCTAssertEqual(fcntl(descriptors[1], F_SETFL, original | O_NONBLOCK), 0)
        let bytes = [UInt8](repeating: 65, count: 4096)
        while bytes.withUnsafeBytes({ Darwin.write(descriptors[1], $0.baseAddress!, $0.count) }) > 0 { }
        XCTAssertEqual(fcntl(descriptors[1], F_SETFL, original), 0)

        let tee = try TranscriptTee(directory: path, issues: Issues(), stdoutFD: descriptors[1])
        tee.start()
        let segment = Segment(source: .recording, start: 1, duration: 1, text: "Keep the written words")
        XCTAssertTrue(tee.emit(segment))
        let state = ShutdownState()
        state.beginDraining()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { state.request() }
        let began = Date()
        try tee.finish(complete: true, shutdown: state)
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.8)
        XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("transcript.txt"), encoding: .utf8), segment.line)
        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathComponent("transcript.json"))) as! [String: Any]
        XCTAssertEqual(summary["complete"] as? Bool, false)
        XCTAssertEqual(summary["segmentCount"] as? Int, 1)
        XCTAssertEqual(fcntl(descriptors[1], F_GETFL) & O_NONBLOCK, original & O_NONBLOCK)
    }
}
