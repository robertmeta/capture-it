import AVFoundation
import Darwin
import Synchronization
import XCTest
@testable import CaptureCore

final class PipelineTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("capture-it-test-\(UUID())")
        try privateDirectory(path)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return path
    }

    private func buffer(frames: Int = 4800, value: Float = 0.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        result.frameLength = AVAudioFrameCount(frames)
        result.floatChannelData![0].update(repeating: value, count: frames)
        return result
    }

    func testWAVRoundTripStaysOneFile() throws {
        let path = try directory()
        let writer = WAVWriter(directory: path)
        try writer.append(AudioPacket(buffer: buffer(), time: 1.5))
        try writer.finish()
        XCTAssertEqual(writer.chunks.count, 1)
        XCTAssertEqual(writer.chunks.map(\.frames).reduce(0, +), 4800)
        for (index, chunk) in writer.chunks.enumerated() {
            XCTAssertTrue(chunk.closed)
            XCTAssertEqual(chunk.start, 1.5, accuracy: 0.00001)
            XCTAssertEqual(index, 0)
            XCTAssertEqual(chunk.file, "recording.wav")
            let file = try AVAudioFile(forReading: path.appendingPathComponent(chunk.file))
            XCTAssertEqual(file.length, 4800)
            let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
            try file.read(into: read)
            XCTAssertEqual(read.floatChannelData![0][0], 0.5, accuracy: 0.0001)
        }
    }

    func testRecognitionOverflowDoesNotLoseRecordedFrames() throws {
        let path = try directory()
        let issues = Issues()
        let lane = AudioLane(source: .mic, directory: path, epoch: 0, issues: issues)
        lane.speechEnabled.store(true, ordering: .releasing)
        lane.startWriter()
        let samples = buffer(frames: 128)
        // No speech consumer: this deliberately fills only the speech queue.
        for _ in 0 ..< 300 {
            lane.accept(samples, hostTime: mach_absolute_time())
            Thread.sleep(forTimeInterval: 0.001)
        }
        lane.finishCapture()
        XCTAssertTrue(lane.waitForWriter())
        XCTAssertTrue(lane.speechOverflow.load(ordering: .acquiring))
        XCTAssertFalse(lane.recordingOverflow.load(ordering: .acquiring))
        XCTAssertEqual(lane.chunks.map(\.frames).reduce(0, +), 300 * 128)
        XCTAssertTrue(issues.all.isEmpty)
    }

    func testTranscriptTeePersistsIdenticalBytesBeforeFinish() throws {
        let path = try directory()
        let screenPath = path.appendingPathComponent("screen.txt")
        let fd = open(screenPath.path, O_CREAT | O_WRONLY, 0o600)
        defer { close(fd) }
        let issues = Issues()
        let tee = try TranscriptTee(directory: path, issues: issues, stdoutFD: fd)
        tee.start()
        let segment = Segment(source: .app, start: 3.25, duration: 1, text: "A known phrase")
        XCTAssertTrue(tee.emit(segment))
        let textURL = path.appendingPathComponent("transcript.txt")
        let deadline = Date().addingTimeInterval(3)
        while (try Data(contentsOf: textURL)).isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(try String(contentsOf: textURL, encoding: .utf8), segment.line)
        try tee.finish(complete: true)
        XCTAssertEqual(try Data(contentsOf: textURL), try Data(contentsOf: screenPath))
        let structured = try JSONDecoder().decode(Segment.self, from: Data(contentsOf: path.appendingPathComponent("transcript.jsonl")))
        XCTAssertEqual(structured.text, "A known phrase")
        XCTAssertTrue(issues.all.isEmpty)
    }

    func testBlockedStdoutDoesNotBlockTranscriptFile() throws {
        signal(SIGPIPE, SIG_IGN)
        let path = try directory()
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let issues = Issues()
        let tee = try TranscriptTee(directory: path, issues: issues, stdoutFD: descriptors[1])
        tee.start()
        for index in 0 ..< 100 {
            XCTAssertTrue(tee.emit(Segment(source: .mic, start: Double(index), duration: 1, text: String(repeating: "speech ", count: 1000))))
        }
        try tee.finish(complete: true)
        let lines = try String(contentsOf: path.appendingPathComponent("transcript.txt"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        XCTAssertFalse(tee.hasFailed)
        XCTAssertTrue(issues.all.contains(where: { $0.contains("stdout stalled") }))
    }

    func testExistingSessionIsNeverOverwritten() throws {
        let path = try directory()
        XCTAssertThrowsError(try privateDirectory(path))
    }

    func testClockDiscontinuityDoesNotCreateAnotherWAV() throws {
        let path = try directory()
        let writer = WAVWriter(directory: path, source: .mic)
        try writer.append(AudioPacket(buffer: buffer(), time: 0))
        XCTAssertThrowsError(try writer.append(AudioPacket(buffer: buffer(), time: 1)))
        try writer.finish()
        XCTAssertEqual(writer.chunks.count, 1)
        XCTAssertTrue(writer.chunks.allSatisfy(\.closed))
    }

    func testClosedStdoutRetainsTranscriptFile() throws {
        signal(SIGPIPE, SIG_IGN)
        let path = try directory()
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        close(descriptors[0])
        defer { close(descriptors[1]) }
        let issues = Issues()
        let tee = try TranscriptTee(directory: path, issues: issues, stdoutFD: descriptors[1])
        tee.start()
        let segment = Segment(source: .mic, start: 0, duration: 1, text: "Saved despite closed pipe")
        XCTAssertTrue(tee.emit(segment))
        try tee.finish(complete: true)
        XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("transcript.txt"), encoding: .utf8), segment.line)
        XCTAssertTrue(issues.all.contains(where: { $0.contains("stdout closed") }))
        XCTAssertFalse(tee.hasFailed)
    }
}
