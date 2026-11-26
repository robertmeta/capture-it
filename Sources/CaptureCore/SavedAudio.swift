import AVFoundation
import Foundation

enum RecordingContainer: String {
    case m4a, wav
}

/// Saved audio uses native decoding and bounded PCM buffers. ALAC retains channel
/// order, exact frame counts and PCM16 capture samples inside an M4A container.
enum SavedAudio {
    static let extensions: Set<String> = ["m4a", "wav", "mp3", "aif", "aiff", "caf"]

    static func encodeM4A(source: URL, destination: URL) throws -> Chunk {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard (1...3).contains(format.channelCount), input.length > 0 else {
            throw CaptureError.message("Audio input must contain samples in one, two or three channels")
        }
        let reserved = try createPrivateFile(destination)
        try reserved.close()
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitDepthHintKey: max(16, Int(input.fileFormat.streamDescription.pointee.mBitsPerChannel))
            ]
            var output: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: settings,
                                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw CaptureError.message("Cannot allocate audio encoding buffer")
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { throw CaptureError.message("Unexpected end of audio input") }
                try output!.write(from: buffer)
            }
            // Closing commits the M4A packet table before validation or publication.
            output = nil
            let committed = try FileHandle(forWritingTo: destination)
            try committed.synchronize()
            try committed.close()
            let saved = try AVAudioFile(forReading: destination)
            guard saved.length == input.length, saved.processingFormat.channelCount == format.channelCount,
                  saved.processingFormat.sampleRate == format.sampleRate else {
                throw CaptureError.message("Encoded M4A differs from the source audio format or duration")
            }
            return Chunk(file: destination.lastPathComponent, source: .recording, start: 0,
                         sampleRate: format.sampleRate, channels: Int(format.channelCount), frames: saved.length, closed: true)
        } catch {
            do { try FileManager.default.removeItem(at: destination) }
            catch { diagnostic("Cannot remove incomplete M4A at \(destination.path): \(error)") }
            throw error
        }
    }

    /// Publish the M4A first. The caller checkpoints its manifest before deleting
    /// the WAV, so interruption always leaves a discoverable complete recording.
    static func finalize(_ chunk: Chunk, in directory: URL) throws -> Chunk {
        guard chunk.closed, chunk.frames > 0 else { throw CaptureError.message("Cannot encode an unfinished recording") }
        let source = directory.appendingPathComponent(chunk.file)
        let destination = source.deletingPathExtension().appendingPathExtension("m4a")
        let staging = directory.appendingPathComponent(".encoding-\(UUID()).m4a")
        let encoded = try encodeM4A(source: source, destination: staging)
        do {
            guard encoded.frames == chunk.frames, encoded.channels == chunk.channels, encoded.sampleRate == chunk.sampleRate else {
                throw CaptureError.message("Recovery audio differs from the session manifest")
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        catch {
            do { try FileManager.default.removeItem(at: staging) }
            catch { diagnostic("Cannot remove staged M4A: \(error)") }
            throw error
        }
        return Chunk(file: destination.lastPathComponent, source: chunk.source, start: chunk.start,
                     sampleRate: encoded.sampleRate, channels: encoded.channels, frames: encoded.frames, closed: true)
    }

    static func importFile(_ source: URL, to directory: URL) throws -> Chunk {
        guard extensions.contains(source.pathExtension.lowercased()) else {
            throw CaptureError.message("Supported audio inputs are M4A, WAV, MP3, AIFF and CAF")
        }
        let destination = directory.appendingPathComponent(directory.lastPathComponent + ".m4a")
        if source.pathExtension.lowercased() == "m4a" {
            let audio = try AVAudioFile(forReading: source)
            guard audio.length > 0, (1...3).contains(audio.processingFormat.channelCount) else {
                throw CaptureError.message("Audio input must contain samples in one, two or three channels")
            }
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return Chunk(file: destination.lastPathComponent, source: .recording, start: 0,
                         sampleRate: audio.processingFormat.sampleRate, channels: Int(audio.processingFormat.channelCount),
                         frames: audio.length, closed: true)
        }
        return try encodeM4A(source: source, destination: destination)
    }
}
