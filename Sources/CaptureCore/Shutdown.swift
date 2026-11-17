import Foundation
import Synchronization

/// Running → draining → interrupted. Automatic stops enter draining too, so
/// Ctrl-C during any shutdown can skip speech without bypassing audio closure.
final class ShutdownState: Sendable {
    private let phase = Atomic<Int>(0)

    var requested: Bool { phase.load(ordering: .acquiring) > 0 }
    var interrupted: Bool { phase.load(ordering: .acquiring) > 1 }

    func request(count: UInt = 1) {
        // Dispatch signal sources may coalesce multiple signals into one event.
        for _ in 0 ..< min(count, 2) {
            while true {
                let current = phase.load(ordering: .acquiring)
                if current >= 2 { return }
                if phase.compareExchange(expected: current, desired: current + 1, ordering: .acquiringAndReleasing).exchanged { break }
            }
        }
    }

    func beginDraining() {
        _ = phase.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing)
    }
}

/// Poll only the control-plane join; audio and file workers keep running.
func waitForDrain(_ group: DispatchGroup, timeout: Double, shutdown: ShutdownState?) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if group.wait(timeout: .now()) == .success { return true }
        if shutdown?.interrupted == true { return false }
        if group.wait(timeout: .now() + .milliseconds(20)) == .success { return true }
    } while Date() < deadline
    return false
}
