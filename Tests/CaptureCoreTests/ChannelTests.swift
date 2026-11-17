import AVFoundation
import XCTest
@testable import CaptureCore

final class ChannelTests: XCTestCase {
    private func buffer(channels: Int, frames: Int, rate: Double = 48_000, value: Float = 0) -> AVAudioPCMBuffer {
        let format = RecordingFormat.pcmFormat(rate: rate, channels: AVAudioChannelCount(channels))
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        result.frameLength = AVAudioFrameCount(frames)
        for channel in 0 ..< channels { result.floatChannelData![channel].update(repeating: value, count: frames) }
        return result
    }

    func testOutOfOrderCallbacksPreserveLRMicAndTimestampOffset() throws {
        let timeline = ChannelTimeline()
        let app = buffer(channels: 2, frames: 960)
        app.floatChannelData![0][0] = 0.4
        app.floatChannelData![1][3] = -0.6
        let mic = buffer(channels: 1, frames: 480, value: 0.8)
        // Mic's later time arrives first. The app owns the earlier timeline.
        try timeline.add(AudioPacket(buffer: mic, time: 1.01), source: .mic)
        try timeline.add(AudioPacket(buffer: app, time: 1), source: .app)
        var packets: [AudioPacket] = []
        try timeline.render { packets.append($0) }
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].time, 0) // Transcript and WAV both start at file time zero.
        XCTAssertEqual(packets[1].time, 0.01)
        XCTAssertEqual(packets[0].buffer.floatChannelData![0][0], 0.4)
        XCTAssertEqual(packets[0].buffer.floatChannelData![1][3], -0.6)
        XCTAssertEqual(packets[0].buffer.floatChannelData![2][479], 0)
        XCTAssertEqual(packets[1].buffer.floatChannelData![2][0], 0.8)
        XCTAssertEqual(packets[1].buffer.floatChannelData![0][0], 0)
        let mono = try RecordingFormat.mono(packets[1].buffer)
        XCTAssertEqual(mono.floatChannelData![0][0], 0.4, accuracy: 0.00001)
    }

    func testDownmixIncludesBothAppChannelsAndMicrophoneWithoutClipping() throws {
        let input = buffer(channels: 3, frames: 4)
        input.floatChannelData![0][0] = 1
        input.floatChannelData![1][1] = 1
        input.floatChannelData![2][2] = 1
        for channel in 0 ..< 3 { input.floatChannelData![channel][3] = 1 }
        let mono = try RecordingFormat.mono(input)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: 4)), [0.25, 0.25, 0.5, 1])
    }

    func testMicResamplingKeepsOneShared48000HzTimeline() throws {
        let timeline = ChannelTimeline()
        try timeline.add(AudioPacket(buffer: buffer(channels: 2, frames: 4800), time: 0), source: .app)
        try timeline.add(AudioPacket(buffer: buffer(channels: 1, frames: 1600, rate: 16_000, value: 0.5), time: 0), source: .mic)
        var channels = [[Float]](repeating: [], count: 3)
        try timeline.render { packet in
            for channel in 0 ..< 3 { channels[channel].append(contentsOf: UnsafeBufferPointer(start: packet.buffer.floatChannelData![channel], count: Int(packet.buffer.frameLength))) }
        }
        XCTAssertEqual(channels[0].count, 4800)
        XCTAssertEqual(channels[2][2400], 0.5, accuracy: 0.01)
    }

    func testLateAndUnboundedTimestampGapsFailExplicitly() throws {
        let timeline = ChannelTimeline()
        try timeline.add(AudioPacket(buffer: buffer(channels: 2, frames: 4800), time: 0), source: .app)
        try timeline.render(through: 0.08) { _ in }
        XCTAssertThrowsError(try timeline.add(AudioPacket(buffer: buffer(channels: 1, frames: 480), time: 0), source: .mic))
        XCTAssertThrowsError(try timeline.add(AudioPacket(buffer: buffer(channels: 2, frames: 480), time: 100), source: .app))
    }

    func testExtensibleWAVReadbackPreservesThreeDiscreteChannels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-it-channels-\(UUID())")
        try privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = buffer(channels: 3, frames: 480)
        for channel in 0 ..< 3 { input.floatChannelData![channel].update(repeating: [0.25, -0.5, 0.75][channel], count: 480) }
        let writer = WAVWriter(directory: directory, maxDataBytes: 480 * 3 * 2)
        try writer.append(AudioPacket(buffer: input, time: 0))
        XCTAssertThrowsError(try writer.append(AudioPacket(buffer: input, time: 0.01)))
        try writer.finish()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recording.wav"])
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("recording.wav"))
        XCTAssertEqual(file.processingFormat.channelCount, 3)
        XCTAssertEqual(file.length, 480)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480)!
        try file.read(into: read)
        for channel in 0 ..< 3 { XCTAssertEqual(read.floatChannelData![channel][0], [0.25, -0.5, 0.75][channel], accuracy: 0.0001) }
        let mono = try RecordingFormat.mono(read)
        XCTAssertEqual(mono.floatChannelData![0][0], 0.3125, accuracy: 0.0001)
    }

    func testConcurrentInputWorkersAssembleExactlyOneAlignedWAV() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-it-workers-\(UUID())")
        try privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let issues = Issues()
        let base = mach_absolute_time()
        let epoch = AVAudioTime.seconds(forHostTime: base)
        let app = CaptureInput(source: .app, epoch: epoch)
        let mic = CaptureInput(source: .mic, epoch: epoch)
        let output = AudioLane(source: .recording, directory: directory, epoch: epoch, issues: issues)
        let assembler = ChannelAssembler(inputs: [app, mic], output: output, epoch: epoch, issues: issues)
        output.startWriter(); assembler.start()
        let appSamples = buffer(channels: 2, frames: 480, value: 0.25)
        let micSamples = buffer(channels: 1, frames: 480, value: 0.75)
        let producers = expectation(description: "both producers")
        producers.expectedFulfillmentCount = 2
        for (input, immutable) in [(app, AudioPacket(buffer: appSamples, time: 0)), (mic, AudioPacket(buffer: micSamples, time: 0))] {
            DispatchQueue.global().async {
                for index in 0 ..< 50 {
                    input.acceptOwned(immutable.buffer, hostTime: base + AVAudioTime.hostTime(forSeconds: Double(index) * 0.01))
                }
                producers.fulfill()
            }
        }
        wait(for: [producers], timeout: 5)
        assembler.finishInputs()
        XCTAssertTrue(assembler.wait())
        XCTAssertTrue(output.waitForWriter())
        XCTAssertTrue(issues.all.isEmpty)
        XCTAssertEqual(output.chunks.count, 1)
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("recording.wav"))
        XCTAssertEqual(file.length, 24_000)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000)!
        try file.read(into: read)
        XCTAssertEqual(read.floatChannelData![0][20_000], 0.25, accuracy: 0.0001)
        XCTAssertEqual(read.floatChannelData![1][20_000], 0.25, accuracy: 0.0001)
        XCTAssertEqual(read.floatChannelData![2][20_000], 0.75, accuracy: 0.0001)
    }
}
