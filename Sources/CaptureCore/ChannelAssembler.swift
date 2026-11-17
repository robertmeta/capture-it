import AVFoundation
import Foundation
import Synchronization

/// One native callback producer and one assembler consumer per input.
final class CaptureInput: @unchecked Sendable {
    let source: Source
    let queue = AudioQueue<AudioPacket>(capacity: 256)
    let overflow = Atomic<Bool>(false)
    let copyFailure = Atomic<Bool>(false)
    let receivedFrames = Atomic<Int64>(0)
    private let epoch: Double

    init(source: Source, epoch: Double) { self.source = source; self.epoch = epoch }

    func acceptOwned(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let time = max(0, AVAudioTime.seconds(forHostTime: hostTime) - epoch)
        if queue.offer(AudioPacket(buffer: buffer, time: time)) {
            receivedFrames.add(Int64(buffer.frameLength), ordering: .relaxed)
        } else { overflow.store(true, ordering: .releasing) }
    }
}

/// The file layout is discrete app-left, app-right, microphone. Recognition
/// explicitly combines these, independent of the player's channel-layout rules.
enum RecordingFormat {
    static let rate = 48_000.0
    static let channels = ["app-left", "app-right", "microphone"]
    static let format = pcmFormat(rate: rate, channels: 3)

    static func pcmFormat(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        if channels <= 2 { return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)! }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
    }

    static func mono(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard input.format.channelCount == 3 else { throw CaptureError.message("Expected app-left/app-right/microphone recording channels") }
        let planar = input.format.commonFormat == .pcmFormatFloat32 && !input.format.isInterleaved
            ? input : try PCMConverter(output: pcmFormat(rate: input.format.sampleRate, channels: 3)).convert(input)
        let format = AVAudioFormat(standardFormatWithSampleRate: input.format.sampleRate, channels: 1)!
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: planar.frameLength), let values = planar.floatChannelData else { throw CaptureError.message("Cannot allocate transcription downmix") }
        output.frameLength = planar.frameLength
        for index in 0 ..< Int(planar.frameLength) {
            output.floatChannelData![0][index] = values[0][index] * 0.25 + values[1][index] * 0.25 + values[2][index] * 0.5
        }
        return output
    }
}

private final class InputNormalizer {
    private let source: Source
    private var native: AVAudioFormat?
    private var planar: PCMConverter?
    private let resampler: PCMConverter

    init(source: Source) {
        self.source = source
        resampler = PCMConverter(output: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RecordingFormat.rate, channels: source == .app ? 2 : 1, interleaved: false)!)
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if let native, native.sampleRate != input.format.sampleRate || native.channelCount != input.format.channelCount {
            throw CaptureError.message("\(source.rawValue) device format changed; recording stopped")
        }
        if planar == nil {
            native = input.format
            planar = PCMConverter(output: RecordingFormat.pcmFormat(rate: input.format.sampleRate, channels: input.format.channelCount))
        }
        let converted = try planar!.convert(input)
        if source == .app {
            guard converted.format.channelCount == 2 else { throw CaptureError.message("Selected app stream is not stereo") }
            return try resampler.convert(converted)
        }
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: input.format.sampleRate, channels: 1)!
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: converted.frameLength), let data = converted.floatChannelData else { throw CaptureError.message("Cannot allocate microphone normalization buffer") }
        mono.frameLength = converted.frameLength
        for frame in 0 ..< Int(converted.frameLength) {
            var value: Float = 0
            for channel in 0 ..< Int(converted.format.channelCount) { value += data[channel][frame] }
            mono.floatChannelData![0][frame] = value / Float(converted.format.channelCount)
        }
        return try resampler.convert(mono)
    }
}

/// Worker-owned timestamp assembler. It preserves separate channels, inserts
/// silence where an input has no samples, and bounds the alignment window.
final class ChannelTimeline {
    private let capacity: Int64
    private var samples: [Float]
    private var cursor: Int64?
    private var end: Int64 = 0
    private var emitted = false
    private var origin: Int64?
    private var sourceEnds: [Source: Int64] = [:]
    private let normalizers = Dictionary(uniqueKeysWithValues: Source.inputs.map { ($0, InputNormalizer(source: $0)) })

    init(windowSeconds: Double = 4) {
        capacity = Int64(RecordingFormat.rate * windowSeconds)
        samples = Array(repeating: 0, count: Int(capacity) * 3)
    }

    func add(_ packet: AudioPacket, source: Source) throws {
        guard let normalizer = normalizers[source], packet.time.isFinite, packet.time >= 0 else { throw CaptureError.message("Invalid capture timestamp or source") }
        let buffer = try normalizer.convert(packet.buffer)
        guard buffer.frameLength > 0, let data = buffer.floatChannelData else { return }
        var start = Int64((packet.time * RecordingFormat.rate).rounded())
        if let previous = sourceEnds[source], abs(start - previous) <= 48 { start = previous }
        if let previous = sourceEnds[source], start < previous { throw CaptureError.message("\(source.rawValue) timestamps moved backward") }
        if cursor == nil || (!emitted && start < cursor!) { cursor = start }
        guard let cursor, start >= cursor else { throw CaptureError.message("\(source.rawValue) audio arrived after the alignment deadline; recording stopped") }
        let last = start + Int64(buffer.frameLength)
        guard last - cursor <= capacity else { throw CaptureError.message("Audio timestamp gap exceeds the bounded alignment window; recording stopped") }
        for offset in 0 ..< Int(buffer.frameLength) {
            let slot = Int((start + Int64(offset)) % capacity) * 3
            if source == .app {
                samples[slot] = data[0][offset]
                samples[slot + 1] = data[1][offset]
            } else { samples[slot + 2] = data[0][offset] }
        }
        sourceEnds[source] = last
        end = max(end, last)
    }

    func render(through time: Double? = nil, emit: (AudioPacket) throws -> Void) throws {
        guard var cursor = cursor else { return }
        let limit = time.map { min(end, Int64(max(0, $0) * RecordingFormat.rate)) } ?? end
        while cursor < limit {
            if time != nil && limit - cursor < 480 { break }
            if !emitted { origin = cursor }
            let frames = min(480, Int(limit - cursor))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: RecordingFormat.format, frameCapacity: AVAudioFrameCount(frames)) else { throw CaptureError.message("Cannot allocate aligned audio") }
            buffer.frameLength = AVAudioFrameCount(frames)
            for frame in 0 ..< frames {
                let slot = Int((cursor + Int64(frame)) % capacity) * 3
                for channel in 0 ..< 3 {
                    buffer.floatChannelData![channel][frame] = samples[slot + channel]
                    samples[slot + channel] = 0
                }
            }
            try emit(AudioPacket(buffer: buffer, time: Double(cursor - origin!) / RecordingFormat.rate))
            cursor += Int64(frames)
            self.cursor = cursor
            emitted = true
        }
    }
}

/// Dedicated assembly worker. Native callbacks, WAV, ASR and tee remain separate.
final class ChannelAssembler: @unchecked Sendable {
    let inputs: [CaptureInput]
    let failed = Atomic<Bool>(false)
    private let output: AudioLane
    private let issues: Issues
    private let epoch: Double
    private let done = DispatchGroup()
    private var started = false

    init(inputs: [CaptureInput], output: AudioLane, epoch: Double, issues: Issues) {
        self.inputs = inputs; self.output = output; self.epoch = epoch; self.issues = issues
    }

    func start() {
        started = true; done.enter()
        DispatchQueue(label: "capture-it.align", qos: .userInitiated).async { [self] in
            defer { output.finishCapture(); done.leave() }
            let timeline = ChannelTimeline()
            do {
                while true {
                    for input in inputs {
                        for _ in 0 ..< 256 {
                            guard let packet = input.queue.poll() else { break }
                            try timeline.add(packet, source: input.source)
                        }
                    }
                    let finished = inputs.allSatisfy { $0.queue.isDrained }
                    let now = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - epoch - 0.5
                    try timeline.render(through: finished ? nil : now) { output.acceptPacket($0) }
                    if finished { break }
                    Thread.sleep(forTimeInterval: 0.002)
                }
            } catch { failed.store(true, ordering: .releasing); issues.add("Channel alignment failed: \(error)") }
        }
    }

    func finishInputs() {
        inputs.forEach { $0.queue.finish() }
        if !started { output.finishCapture() }
    }
    func wait(timeout: Double = 15) -> Bool { done.wait(timeout: .now() + timeout) == .success }
}
