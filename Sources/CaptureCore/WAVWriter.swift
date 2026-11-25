import AVFoundation
import Foundation

/// Converts on a worker, never in the device callback.
final class PCMConverter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    let outputFormat: AVAudioFormat

    init(output: AVAudioFormat) { outputFormat = output }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == outputFormat { return input }
        if input.format != inputFormat {
            guard let next = AVAudioConverter(from: input.format, to: outputFormat) else {
                throw CaptureError.message("Unsupported audio conversion: \(input.format) to \(outputFormat)")
            }
            next.primeMethod = .none
            converter = next
            inputFormat = input.format
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate)) + 256
        guard let result = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity), let converter else {
            throw CaptureError.message("Cannot allocate converted audio")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: result, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? CaptureError.message("Audio conversion failed") as NSError }
        return result
    }
}

/// One PCM16 WAV, using WAVE_FORMAT_EXTENSIBLE for more than two channels.
final class WAVWriter {
    private let directory: URL
    private let file: String
    private let source: Source
    private let maxDataBytes: UInt32
    private var handle: FileHandle?
    private var converter: PCMConverter?
    private var format: AVAudioFormat?
    private var checkpointFrames: Int64 = 0
    private var expectedTime: Double?
    private(set) var chunks: [Chunk] = []

    init(directory: URL, source: Source = .recording, file: String = "recording.wav", maxDataBytes: UInt32 = UInt32.max - 60) {
        self.directory = directory; self.source = source; self.maxDataBytes = maxDataBytes; self.file = file
    }

    func append(_ packet: AudioPacket) throws {
        let input = packet.buffer
        guard input.frameLength > 0 else { return }
        let duration = Double(input.frameLength) / input.format.sampleRate
        if let expectedTime, abs(packet.time - expectedTime) > max(0.02, duration * 2) {
            throw CaptureError.message("Recording timeline is discontinuous; stopping rather than misaligning channels")
        }
        expectedTime = packet.time + duration
        if format == nil {
            let output = RecordingFormat.pcmFormat(rate: input.format.sampleRate, channels: input.format.channelCount)
            format = output
            converter = PCMConverter(output: output)
        }
        guard let format, let converter,
              input.format.sampleRate == format.sampleRate,
              input.format.channelCount == format.channelCount else {
            throw CaptureError.message("\(source.rawValue) audio format changed; recording stopped to preserve timing")
        }
        let buffer = try converter.convert(input)
        guard let samples = buffer.floatChannelData else { throw CaptureError.message("Missing PCM audio samples") }
        let channels = Int(format.channelCount)
        if handle == nil {
            guard chunks.isEmpty else { throw CaptureError.message("WAV writer is already closed") }
            try begin(at: packet.time, format: format)
        }
        let index = chunks.count - 1
        let count = Int(buffer.frameLength)
        guard (chunks[index].frames + Int64(count)) * Int64(channels * 2) <= Int64(maxDataBytes) else {
            throw CaptureError.message("Single WAV reached its RIFF size limit; recording stopped and the file is retained")
        }
        var data = Data(count: count * channels * 2)
        data.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: Int16.self)
            for offset in 0 ..< count {
                for channel in 0 ..< channels {
                    let value = samples[channel][offset]
                    let bounded = value.isFinite ? min(1, max(-1, value)) : 0
                    output[offset * channels + channel] = Int16((bounded * 32767).rounded()).littleEndian
                }
            }
        }
        try handle!.write(contentsOf: data)
        chunks[index].frames += Int64(count)
        checkpointFrames += Int64(count)
        if checkpointFrames >= Int64(format.sampleRate) { try checkpoint(); checkpointFrames = 0 }
    }

    private func begin(at time: Double, format: AVAudioFormat) throws {
        handle = try createPrivateFile(directory.appendingPathComponent(file))
        chunks.append(Chunk(file: file, source: source, start: max(0, time), sampleRate: format.sampleRate, channels: Int(format.channelCount), frames: 0, closed: false))
        try handle!.write(contentsOf: header(chunks.last!))
    }

    private func header(_ chunk: Chunk) -> Data {
        var result = Data()
        func string(_ text: String) { result.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { result.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { result.append(contentsOf: $0) } }
        let bytes = UInt32(chunk.frames * Int64(chunk.channels * 2))
        let extended = chunk.channels > 2
        string("RIFF"); u32((extended ? 60 : 36) + bytes); string("WAVEfmt "); u32(extended ? 40 : 16); u16(extended ? 0xfffe : 1)
        u16(UInt16(chunk.channels)); u32(UInt32(chunk.sampleRate)); u32(UInt32(chunk.sampleRate) * UInt32(chunk.channels * 2))
        u16(UInt16(chunk.channels * 2)); u16(16)
        if extended {
            u16(22); u16(16); u32(0) // Discrete channels; microphone is not a center speaker.
            result.append(contentsOf: [1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113])
        }
        string("data"); u32(bytes)
        return result
    }

    private func checkpoint() throws {
        guard let handle, let chunk = chunks.last else { return }
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(chunk))
        try handle.seek(toOffset: end)
        try handle.synchronize()
    }

    private func closeChunk() throws {
        guard let handle else { return }
        try checkpoint()
        try handle.close()
        self.handle = nil
        chunks[chunks.count - 1].closed = true
        checkpointFrames = 0
    }

    func finish() throws { try closeChunk() }
}
