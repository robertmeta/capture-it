import Darwin
import Foundation
import Synchronization

/// Multiple speech tasks can publish; file I/O never holds the mailbox lock.
final class Mailbox<Element>: @unchecked Sendable {
    private let condition = NSCondition()
    private var slots: [Element?]
    private var read = 0
    private var write = 0
    private var count = 0
    private var closed = false

    init(capacity: Int) { slots = Array(repeating: nil, count: capacity) }
    @discardableResult func offer(_ item: Element) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !closed, count < slots.count else { return false }
        slots[write] = item; write = (write + 1) % slots.count; count += 1
        condition.signal(); return true
    }
    func take() -> Element? {
        condition.lock(); defer { condition.unlock() }
        while count == 0 && !closed { condition.wait() }
        guard count > 0 else { return nil }
        let result = slots[read]; slots[read] = nil
        read = (read + 1) % slots.count; count -= 1
        return result
    }
    func finish() { condition.lock(); closed = true; condition.broadcast(); condition.unlock() }
}

/// stdout is independently buffered and uses nonblocking writes with a deadline.
/// A stopped reader can never hold up the transcript file or an audio worker.
final class ScreenWriter: @unchecked Sendable {
    private let queue: AudioQueue<Data>
    private let done = DispatchGroup()
    private let fd: Int32
    private let issues: Issues
    private let failed = Atomic<Bool>(false)
    // Adjacent meetings may briefly share stdout while the old recognizer drains.
    private static let flagsByFD = Mutex<[Int32: (original: Int32, count: Int)]>([:])
    private let holdsFlags = Atomic<Bool>(false)
    private let timeout: TimeInterval

    init(fd: Int32 = STDOUT_FILENO, issues: Issues, capacity: Int = 512, timeout: TimeInterval = 2) {
        self.fd = fd; self.issues = issues; self.timeout = timeout
        queue = AudioQueue(capacity: capacity)
    }

    func start() {
        done.enter()
        DispatchQueue(label: "capture-it.transcript.screen", qos: .utility).async { [self] in
            defer { done.leave() }
            guard acquireFlags() else { fail("Cannot configure transcript stdout"); return }
            defer { restoreFlags() }
            while let data = queue.take() {
                if failed.load(ordering: .acquiring) { continue }
                var offset = 0
                let deadline = Date().addingTimeInterval(timeout)
                while offset < data.count {
                    if failed.load(ordering: .acquiring) { break }
                    if Date() > deadline { fail("Transcript stdout stalled; file output continues"); break }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let result = poll(&descriptor, 1, 50)
                    if result < 0 { if errno == EINTR { continue }; fail("Transcript stdout poll failed"); break }
                    if result == 0 { continue }
                    let written = data.withUnsafeBytes { bytes in
                        Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(4096, data.count - offset))
                    }
                    if written > 0 { offset += written }
                    else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        fail("Transcript stdout closed or failed; file output continues"); break
                    }
                }
            }
        }
    }

    private func fail(_ message: String) {
        failed.store(true, ordering: .releasing); issues.add(message)
    }

    // Exactly one producer: the transcript file worker.
    func offer(_ data: Data) {
        guard !failed.load(ordering: .acquiring) else { return }
        if !queue.offer(data) { fail("Transcript stdout queue filled; file output continues") }
    }
    func finish(timeout: Double = 5, shutdown: ShutdownState? = nil) -> Bool {
        queue.finish()
        var stopped = waitForDrain(done, timeout: timeout, shutdown: shutdown)
        if !stopped, shutdown?.interrupted == true {
            failed.store(true, ordering: .releasing)
            stopped = done.wait(timeout: .now() + .milliseconds(100)) == .success
        }
        if !stopped { restoreFlags() }
        return stopped
    }
    private func acquireFlags() -> Bool {
        Self.flagsByFD.withLock { table in
            if var entry = table[fd] {
                entry.count += 1; table[fd] = entry
            } else {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
                table[fd] = (flags, 1)
            }
            holdsFlags.store(true, ordering: .releasing)
            return true
        }
    }

    private func restoreFlags() {
        Self.flagsByFD.withLock { table in
            guard holdsFlags.exchange(false, ordering: .acquiringAndReleasing), var entry = table[fd] else { return }
            entry.count -= 1
            if entry.count == 0 {
                _ = fcntl(fd, F_SETFL, entry.original)
                table.removeValue(forKey: fd)
            } else { table[fd] = entry }
        }
    }
}

/// Appends each final segment to durable files before teeing identical bytes.
final class TranscriptTee: @unchecked Sendable {
    private let queue = Mailbox<Segment>(capacity: 512)
    private let done = DispatchGroup()
    private let screen: ScreenWriter
    private let text: FileHandle
    private let jsonl: FileHandle
    private let directory: URL
    private let issues: Issues
    private let failed = Atomic<Bool>(false)
    private var segmentCount = 0 // file worker owns; read only after join

    init(directory: URL, issues: Issues, stdoutFD: Int32 = STDOUT_FILENO) throws {
        self.directory = directory; self.issues = issues
        text = try createPrivateFile(directory.appendingPathComponent("transcript.txt"))
        jsonl = try createPrivateFile(directory.appendingPathComponent("transcript.jsonl"))
        screen = ScreenWriter(fd: stdoutFD, issues: issues)
    }

    var hasFailed: Bool { failed.load(ordering: .acquiring) }

    func start() {
        screen.start(); done.enter()
        DispatchQueue(label: "capture-it.transcript.file", qos: .utility).async { [self] in
            defer { done.leave() }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                while let segment = queue.take() {
                    let bytes = Data(segment.line.utf8)
                    var structured = try encoder.encode(segment); structured.append(10)
                    try text.write(contentsOf: bytes)
                    try jsonl.write(contentsOf: structured)
                    try text.synchronize(); try jsonl.synchronize()
                    segmentCount += 1
                    screen.offer(bytes)
                }
                try text.close(); try jsonl.close()
            } catch { failed.store(true, ordering: .releasing); issues.add("Transcript file failed: \(error)") }
        }
    }

    @discardableResult func emit(_ segment: Segment) -> Bool {
        guard !hasFailed else { return false }
        if !queue.offer(segment) {
            failed.store(true, ordering: .releasing)
            issues.add("Transcript file queue filled; transcription incomplete, recording continues")
            return false
        }
        return true
    }

    func finish(complete: Bool, timeout: Double = 10, shutdown: ShutdownState? = nil) throws {
        queue.finish()
        var filesStopped = waitForDrain(done, timeout: timeout, shutdown: shutdown)
        if !filesStopped, shutdown?.interrupted == true {
            filesStopped = done.wait(timeout: .now() + .milliseconds(100)) == .success
        }
        guard filesStopped else {
            _ = screen.finish(shutdown: shutdown)
            throw CaptureError.message("Transcript file worker did not stop; saved audio is retained")
        }
        if !screen.finish(shutdown: shutdown) { issues.add("Transcript stdout worker did not stop") }
        struct Document: Encodable { let complete: Bool; let segmentCount: Int; let segmentsFile: String }
        try atomicJSON(Document(complete: complete && !hasFailed && shutdown?.interrupted != true, segmentCount: segmentCount, segmentsFile: "transcript.jsonl"), at: directory.appendingPathComponent("transcript.json"))
    }
}
