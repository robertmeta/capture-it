import AVFoundation
import Foundation
import XCTest
@testable import CaptureCore

final class SavedAudioTests: XCTestCase {
    func testM4AFinalizationPreservesCaptureFramesAndAllThreeChannels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-it-m4a-\(UUID())")
        try privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = RecordingFormat.pcmFormat(rate: 48000, channels: 3)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8193)!
        buffer.frameLength = 8193
        for channel in 0..<3 {
            buffer.floatChannelData![channel].update(repeating: [0.25, -0.5, 0.75][channel], count: 8193)
        }
        let writer = WAVWriter(directory: directory)
        try writer.append(AudioPacket(buffer: buffer, time: 0))
        try writer.finish()
        let chunk = try SavedAudio.finalize(writer.chunks[0], in: directory)
        XCTAssertEqual(chunk.file, "recording.m4a")
        XCTAssertEqual(chunk.frames, 8193)
        let original = try AVAudioFile(forReading: directory.appendingPathComponent("recording.wav"))
        let encoded = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.file))
        let before = AVAudioPCMBuffer(pcmFormat: original.processingFormat, frameCapacity: 8193)!
        let after = AVAudioPCMBuffer(pcmFormat: encoded.processingFormat, frameCapacity: 8193)!
        try original.read(into: before)
        try encoded.read(into: after)
        for channel in 0..<3 {
            for frame in 0..<8193 {
                XCTAssertEqual(before.floatChannelData![channel][frame], after.floatChannelData![channel][frame])
            }
        }
        var manifest = Manifest(app: "fixture", microphone: "fixture", locale: "en-US")
        manifest.recording = "complete"
        manifest.chunks = [chunk]
        try atomicJSON(manifest, at: directory.appendingPathComponent("session.json"))
        XCTAssertEqual(try HookEvent.load(session: directory, transcriptDirectory: nil).audio,
                       directory.appendingPathComponent(chunk.file).path)
        XCTAssertThrowsError(try SavedAudio.finalize(writer.chunks[0], in: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording.wav").path))
        XCTAssertEqual(try AVAudioFile(forReading: directory.appendingPathComponent(chunk.file)).length, 8193)
    }

    func testMonoAndStereoInputDownmixesKeepTheirLevel() throws {
        for channels: AVAudioChannelCount in [1, 2] {
            let format = RecordingFormat.pcmFormat(rate: 44100, channels: channels)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!
            buffer.frameLength = 441
            for channel in 0..<Int(channels) {
                buffer.floatChannelData![channel].update(repeating: 0.5, count: 441)
            }
            let mono = try RecordingFormat.mono(buffer)
            XCTAssertEqual(mono.format.sampleRate, 44100)
            XCTAssertEqual(mono.floatChannelData![0][440], 0.5)
        }
    }
}
