import AVFoundation
import Foundation
import XCTest
@testable import CaptureCore

final class HookTests: XCTestCase {
    private func session() throws -> (URL, Manifest) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-it-hooks-\(UUID())")
        try privateDirectory(directory)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let format = RecordingFormat.pcmFormat(rate: 48000, channels: 3)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for channel in 0 ..< 3 { buffer.floatChannelData![channel].update(repeating: 0, count: 480) }
        let writer = WAVWriter(directory: directory)
        try writer.append(AudioPacket(buffer: buffer, time: 0))
        try writer.finish()
        var metadata = Manifest(app: "fixture", microphone: "fixture", locale: "en-US")
        metadata.recording = "complete"; metadata.transcription = "disabled"
        metadata.chunks = writer.chunks
        try atomicJSON(metadata, at: directory.appendingPathComponent("session.json"))
        return (directory, metadata)
    }

    func testHooksRejectUnclosedAndMismatchedAudio() throws {
        let (directory, initial) = try session()
        var metadata = initial
        metadata.chunks[0].closed = false
        try atomicJSON(metadata, at: directory.appendingPathComponent("session.json"))
        XCTAssertThrowsError(try HookEvent.load(session: directory, transcriptDirectory: nil))
        metadata.chunks[0].closed = true
        metadata.chunks[0].frames += 1
        try atomicJSON(metadata, at: directory.appendingPathComponent("session.json"))
        XCTAssertThrowsError(try HookEvent.load(session: directory, transcriptDirectory: nil))
    }

    func testAudioOnlyEventDoesNotInventTranscriptOrCompletion() throws {
        let (directory, _) = try session()
        let event = try HookEvent.load(session: directory, transcriptDirectory: nil)
        XCTAssertNil(event.transcript)
        XCTAssertNil(event.transcriptComplete)
        XCTAssertEqual(event.recordingStatus, "complete")
        XCTAssertTrue(event.wav.hasPrefix("/"))
        XCTAssertThrowsError(try HookEvent.load(session: directory, transcriptDirectory: directory.appendingPathComponent("missing")))
    }

    func testHookTimeoutAndExecutableValidation() {
        XCTAssertThrowsError(try HookOptions(timeout: .nan).validate())
        XCTAssertThrowsError(try HookOptions(timeout: 0).validate())
        XCTAssertThrowsError(try HookOptions(executables: [URL(fileURLWithPath: "/tmp")]).validate())
        XCTAssertThrowsError(try HookOptions(executables: [URL(fileURLWithPath: "/missing-hook")]).validate())
    }
}
