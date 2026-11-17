@preconcurrency import ApplicationServices
import Foundation
import Synchronization

struct MeetingMetadata: Codable, Sendable, Equatable {
    var title: String?
    var source: String?
    var verified: Bool
    var status: String
    var windowTitle: String?
}

enum MeetingTitlePolicy {
    static func clean(_ value: String) -> String {
        String(value.components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(256))
    }

    static func choose(titles: [String], appName: String) -> MeetingMetadata {
        let generic = Set([appName.lowercased(), "microsoft teams", "teams", "slack", "zoom", "zoom workplace",
                           "google meet", "meet", "chat", "chats", "activity", "calendar", "calls", "home", "settings"])
        var candidates: [String: String] = [:]
        for raw in titles {
            let windowTitle = clean(raw)
            var title = windowTitle
            for name in generic.sorted(by: { $0.count > $1.count }) {
                for separator in [" | ", " — ", " – ", " - "] {
                    let suffix = separator + name
                    if title.lowercased().hasSuffix(suffix) { title.removeLast(suffix.count) }
                }
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, !generic.contains(title.lowercased()) { candidates[title] = windowTitle }
        }
        guard candidates.count == 1, let (title, windowTitle) = candidates.first else {
            return MeetingMetadata(verified: false, status: candidates.isEmpty ? "unknown" : "ambiguous")
        }
        return MeetingMetadata(title: title, source: "accessibility-window-title", verified: false,
                               status: "candidate", windowTitle: windowTitle)
    }
}

/// Reads only the selected PID's window titles on a separate bounded AX worker.
/// A window title is evidence, not proof of a meeting subject or active speaker.
final class MeetingObserver: @unchecked Sendable {
    private let pid: pid_t?
    private let appName: String
    private let lock = NSLock()
    private var value: MeetingMetadata
    private let stopped = Atomic<Bool>(false)
    private let timer: DispatchSourceTimer
    private let explicit: Bool

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult static func requestPermission() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    init(pid: pid_t?, appName: String, title: String?) {
        self.pid = pid; self.appName = appName; explicit = title != nil
        value = title.map { MeetingMetadata(title: MeetingTitlePolicy.clean($0), source: "explicit", verified: true, status: "provided") }
            ?? MeetingMetadata(verified: false, status: Self.isTrusted ? "unknown" : "permission-required")
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "capture-it.meeting-title", qos: .utility))
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
    }

    deinit { timer.cancel() }
    var snapshot: MeetingMetadata { lock.lock(); defer { lock.unlock() }; return value }
    func stop() { stopped.store(true, ordering: .releasing); timer.cancel() }

    private func refresh() {
        guard !explicit, !stopped.load(ordering: .acquiring) else { return }
        let next = read()
        guard !stopped.load(ordering: .acquiring) else { return }
        lock.lock(); value = next; lock.unlock()
    }

    private func read() -> MeetingMetadata {
        guard Self.isTrusted else { return MeetingMetadata(verified: false, status: "permission-required") }
        guard let pid else { return MeetingMetadata(verified: false, status: "unavailable") }
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, 0.15) == .success else {
            return MeetingMetadata(verified: false, status: "unavailable")
        }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count) == .success else {
            return MeetingMetadata(verified: false, status: "unavailable")
        }
        // Never choose from a truncated subset: hidden candidates make it ambiguous.
        guard count <= 8 else { return MeetingMetadata(verified: false, status: "ambiguous") }
        if count == 0 { return MeetingMetadata(verified: false, status: "unknown") }
        var array: CFArray?
        guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, count, &array) == .success,
              let windows = array as? [AXUIElement] else { return MeetingMetadata(verified: false, status: "unavailable") }
        var titles: [String] = []
        for window in windows {
            if stopped.load(ordering: .acquiring) { return MeetingMetadata(verified: false, status: "unavailable") }
            guard AXUIElementSetMessagingTimeout(window, 0.15) == .success else {
                return MeetingMetadata(verified: false, status: "unavailable")
            }
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else {
                return MeetingMetadata(verified: false, status: "unavailable")
            }
            if let title = title as? String { titles.append(title) }
        }
        return MeetingTitlePolicy.choose(titles: titles, appName: appName)
    }
}
