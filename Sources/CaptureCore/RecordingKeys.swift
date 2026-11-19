import Darwin
import Foundation

/// Foreground-terminal q requests a drain; it never escalates an interrupt.
final class RecordingKeys {
    private let queue = DispatchQueue(label: "capture-it.recording-keys", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private let descriptor: Int32
    private var original: termios
    private var active = true

    init?(shutdown: ShutdownState) {
        guard isatty(STDIN_FILENO) == 1, tcgetpgrp(STDIN_FILENO) == getpgrp() else { return nil }
        // A separate open keeps stdin's file flags and buffered picker input intact.
        let fd = open("/dev/tty", O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { diagnostic("Keyboard stop unavailable; use Ctrl-C"); return nil }
        var saved = termios()
        guard tcgetattr(fd, &saved) == 0 else {
            close(fd); diagnostic("Cannot read terminal settings; use Ctrl-C"); return nil
        }
        var mode = saved
        mode.c_lflag &= ~tcflag_t(ICANON | ECHO) // Preserve ISIG and Ctrl-C delivery.
        withUnsafeMutableBytes(of: &mode.c_cc) { bytes in
            bytes[Int(VMIN)] = 1; bytes[Int(VTIME)] = 0
        }
        guard tcsetattr(fd, TCSANOW, &mode) == 0 else {
            close(fd); diagnostic("Cannot enable keyboard stop; use Ctrl-C"); return nil
        }
        descriptor = fd; original = saved
        let source = DispatchSource.makeTimerSource(queue: queue)
        timer = source
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count > 0, bytes.prefix(count).contains(113) { shutdown.beginDraining() }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                diagnostic("Keyboard input unavailable; use Ctrl-C to stop recording")
                source.setEventHandler {}; source.cancel()
            }
        }
        timer.resume()
    }

    func stop() {
        // The read is nonblocking. Serialize restoration before CLI.run returns
        // and main calls exit; an asynchronous cancel handler alone is too late.
        queue.sync {
            guard active else { return }
            active = false
            timer.setEventHandler {}
            timer.cancel()
            if tcgetpgrp(descriptor) == getpgrp(), tcsetattr(descriptor, TCSANOW, &original) != 0 {
                diagnostic("Cannot restore terminal settings: \(String(cString: strerror(errno)))")
            }
            close(descriptor)
        }
    }

    deinit { stop() }
}
