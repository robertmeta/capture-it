import Darwin
import FluidHookSupport
import Foundation
import Synchronization

/// The helper owns this foreground dialogue for the lifetime of its process.
/// Cancellation during an assignment takes effect after the confirmed name is saved.
final class SpeakerTerminal {
    private static let interrupted = Atomic<Bool>(false)
    private let input: Int32
    var cancelled: Bool { Self.interrupted.load(ordering: .relaxed) }

    init() throws {
        input = open("/dev/tty", O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw HookFailure("Speaker review needs a foreground terminal") }
        signal(SIGINT) { _ in SpeakerTerminal.interrupted.store(true, ordering: .relaxed) }
        // Review stdout is routed to stderr by the CLI. Flush before waiting for input.
        setvbuf(stdout, nil, _IONBF, 0)
    }

    deinit { close(input) }

    func name(for id: String) throws -> String? {
        print("Who is \(id)? ", terminator: "")
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        while !cancelled {
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw HookFailure("Cannot read speaker review input") }
            let count = read(input, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count >= 0 else { throw HookFailure("Cannot read speaker name") }
            guard count > 0 else { return nil }
            line.append(contentsOf: buffer.prefix(count))
            if line.last == 10 {
                return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
