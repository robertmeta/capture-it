import Darwin
import Foundation

/// A scroll region keeps the last row available for controls while transcript lines continue above it.
private final class RecordingFooter: @unchecked Sendable {
    private var rows = 0
    private var columns = 0
    private let enabled = isatty(STDERR_FILENO) == 1 && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    private let label = "[q] Quit   [n] New meeting"

    func refresh() {
        guard enabled else { return }
        var window = winsize()
        guard ioctl(STDERR_FILENO, TIOCGWINSZ, &window) == 0 else { return }
        let height = Int(window.ws_row), width = Int(window.ws_col)
        guard height > 2, width > 2 else { stop(); return }
        guard height != rows || width != columns else { return }
        rows = height; columns = width
        write("\u{1B}[1;\(height - 1)r\u{1B}[\(height);1H\u{1B}[2K\(label.prefix(width - 1))\u{1B}[\(height - 1);1H\n")
    }

    func stop() {
        if rows > 0 { write("\u{1B}[r\u{1B}[\(rows);1H\u{1B}[2K"); rows = 0 }
    }

    private func write(_ text: String) {
        Data(text.utf8).withUnsafeBytes { _ = Darwin.write(STDERR_FILENO, $0.baseAddress!, $0.count) }
    }
}

/// Keyboard control runs independently of capture and processing.
final class RecordingKeys {
    private let queue = DispatchQueue(label: "capture-it.recording-keys", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private let descriptor: Int32
    private var original: termios
    private var active = true

    private let footer = RecordingFooter()

    init?(shutdown: ShutdownState, nextMeeting: @escaping @Sendable () -> Void) {
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
        timer.setEventHandler { [footer] in
            footer.refresh()
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count > 0, bytes.prefix(count).contains(113) { shutdown.beginDraining() }
            else if count > 0, bytes.prefix(count).contains(110), !shutdown.requested { nextMeeting() }
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
            footer.stop()
            close(descriptor)
        }
    }

    deinit { stop() }
}
