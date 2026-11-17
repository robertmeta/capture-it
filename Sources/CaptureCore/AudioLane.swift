import AVFoundation
import Foundation
import Synchronization

/// One producer (device callback), with independent recording and speech consumers.
final class AudioLane: @unchecked Sendable {
    let source: Source
    let wav = AudioQueue<AudioPacket>(capacity: 256)
    let speech = AudioQueue<AudioPacket>(capacity: 256)
    let recordingOverflow = Atomic<Bool>(false)
    let speechOverflow = Atomic<Bool>(false)
    let speechEnabled = Atomic<Bool>(false)
    let copyFailure = Atomic<Bool>(false)
    private let lock = NSLock()
    private var savedChunks: [Chunk] = []
    private let writer: WAVWriter
    private let done = DispatchGroup()
    private let issues: Issues
    private let epoch: Double

    init(source: Source, directory: URL, epoch: Double, issues: Issues) {
        self.source = source; self.epoch = epoch; self.issues = issues
        writer = WAVWriter(directory: directory, source: source)
    }

    var chunks: [Chunk] { lock.lock(); defer { lock.unlock() }; return savedChunks }

    func startWriter() {
        done.enter()
        DispatchQueue(label: "capture-it.wav.\(source.rawValue)", qos: .userInitiated).async { [self] in
            defer { done.leave() }
            do {
                while let packet = wav.take() {
                    try writer.append(packet)
                    lock.lock(); savedChunks = writer.chunks; lock.unlock()
                }
                try writer.finish()
            } catch {
                issues.add("\(source.rawValue) WAV writer failed: \(error)")
                recordingOverflow.store(true, ordering: .releasing)
                do { try writer.finish() } catch { issues.add("\(source.rawValue) WAV close failed: \(error)") }
            }
            lock.lock(); savedChunks = writer.chunks; lock.unlock()
        }
    }

    // Callback work is bounded copying and two non-waiting queue offers.
    func accept(_ input: AVAudioPCMBuffer, hostTime: UInt64) {
        guard input.frameLength > 0 else { return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            copyFailure.store(true, ordering: .releasing); return
        }
        copy.frameLength = input.frameLength
        let incoming = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let outgoing = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard incoming.count == outgoing.count else { copyFailure.store(true, ordering: .releasing); return }
        for index in incoming.indices {
            guard let src = incoming[index].mData, let dst = outgoing[index].mData,
                  incoming[index].mDataByteSize <= outgoing[index].mDataByteSize else {
                copyFailure.store(true, ordering: .releasing); return
            }
            memcpy(dst, src, Int(incoming[index].mDataByteSize))
        }
        acceptOwned(copy, hostTime: hostTime)
    }

    // The caller transfers a freshly copied buffer and must never mutate it.
    func acceptOwned(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let time = max(0, AVAudioTime.seconds(forHostTime: hostTime) - epoch)
        acceptPacket(AudioPacket(buffer: buffer, time: time))
    }

    func acceptPacket(_ packet: AudioPacket) {
        if !wav.offer(packet) { recordingOverflow.store(true, ordering: .releasing) }
        if speechEnabled.load(ordering: .acquiring), !speech.offer(packet) {
            speechOverflow.store(true, ordering: .releasing)
            speechEnabled.store(false, ordering: .releasing)
        }
    }

    func finishCapture() {
        speechEnabled.store(false, ordering: .releasing)
        wav.finish(); speech.finish()
    }

    func waitForWriter(timeout: Double = 15) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }
}
