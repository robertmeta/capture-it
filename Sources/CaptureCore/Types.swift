import AVFoundation
import Foundation
import Synchronization

public enum CaptureError: Error, CustomStringConvertible {
    case message(String)
    case audio(OSStatus, String)
    public var description: String {
        switch self {
        case .message(let text): return text
        case .audio(let status, let operation): return "\(operation): Core Audio error \(status)"
        }
    }
}

func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw CaptureError.audio(status, operation)
    }
}

public enum Source: String, Codable, Sendable, CaseIterable {
    case app, mic, recording
    static let inputs: [Source] = [.app, .mic]
}

// Buffers are copied at the capture boundary and immutable after publication.
struct AudioPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let time: Double
}

/// A bounded single-producer/single-consumer ring. Only the consumer waits.
/// Release/acquire publication protects slots; producers never wait on a lock.
final class AudioQueue<Element>: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Element?>
    private let capacity: Int
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)
    private let closed = Atomic<Bool>(false)
    private let ready = DispatchSemaphore(value: 0)

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity + 1
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: nil, count: self.capacity)
    }

    deinit { storage.deinitialize(count: capacity); storage.deallocate() }

    @discardableResult func offer(_ value: Element) -> Bool {
        guard !closed.load(ordering: .acquiring) else { return false }
        let write = writeIndex.load(ordering: .relaxed)
        let next = (write + 1) % capacity
        guard next != readIndex.load(ordering: .acquiring) else { return false }
        storage[write] = value
        writeIndex.store(next, ordering: .releasing)
        ready.signal()
        return true
    }

    func take() -> Element? {
        while true {
            ready.wait()
            let read = readIndex.load(ordering: .relaxed)
            if read != writeIndex.load(ordering: .acquiring) {
                let value = storage[read]
                storage[read] = nil
                readIndex.store((read + 1) % capacity, ordering: .releasing)
                return value
            }
            if closed.load(ordering: .acquiring) { return nil }
        }
    }

    /// Nonblocking read for the single assembler consuming two input rings.
    func poll() -> Element? {
        guard ready.wait(timeout: .now()) == .success else { return nil }
        let read = readIndex.load(ordering: .relaxed)
        guard read != writeIndex.load(ordering: .acquiring) else { return nil }
        let value = storage[read]
        storage[read] = nil
        readIndex.store((read + 1) % capacity, ordering: .releasing)
        return value
    }

    var isDrained: Bool {
        closed.load(ordering: .acquiring) && readIndex.load(ordering: .acquiring) == writeIndex.load(ordering: .acquiring)
    }

    // Call after the producer stops. Additional calls are harmless.
    func finish() { closed.store(true, ordering: .releasing); ready.signal() }
}

/// Shared control-plane state. Never accessed from audio callbacks.
final class Issues: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ text: String) { lock.lock(); defer { lock.unlock() }; if !entries.contains(text) { entries.append(text) } }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

func privateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard mkdir(url.path, 0o700) == 0 else {
        throw CaptureError.message("Cannot create new session \(url.path): \(String(cString: strerror(errno))). Choose a new output directory.")
    }
}

func createPrivateFile(_ url: URL) throws -> FileHandle {
    let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else { throw CaptureError.message("Cannot create \(url.path): \(String(cString: strerror(errno)))") }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

func atomicJSON<T: Encodable>(_ value: T, at url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

struct Chunk: Codable, Sendable {
    let file: String
    let source: Source
    let start: Double
    let sampleRate: Double
    let channels: Int
    var frames: Int64
    var closed: Bool
}

struct Segment: Codable, Sendable {
    let source: Source
    let start: Double
    let duration: Double
    let text: String
    var line: String {
        let seconds = max(0, start)
        let stamp = String(format: "%02d:%02d:%06.3f", Int(seconds) / 3600, (Int(seconds) / 60) % 60, seconds.truncatingRemainder(dividingBy: 60))
        let label = source == .recording ? "" : "[\(source.rawValue)] "
        return "[\(stamp)] \(label)\(text.replacingOccurrences(of: "\n", with: " "))\n"
    }
}

struct Manifest: Codable {
    var version = 2
    var startedAt = ISO8601DateFormatter().string(from: Date())
    var app: String
    var microphone: String
    var locale: String
    var recording = "starting"
    var transcription = "starting"
    var chunks: [Chunk] = []
    var issues: [String] = []
    var channelLayout: [String]? = nil
    var inputFrames: [String: Int64]? = nil
    var selectedProcessID: Int32? = nil
    var microphoneSelection: String? = nil
    var microphoneNote: String? = nil
    var meeting: MeetingMetadata? = nil
}

public let captureItVersion = "0.2.5"
