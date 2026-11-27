import Foundation

enum CaptureDefaults {
    static func stem(_ query: String, fallback: String) -> String {
        func sanitize(_ value: String) -> String {
            let withoutGlob = value.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
            let parts = withoutGlob.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted)
            return parts.filter { !$0.isEmpty }.joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        }
        let search = sanitize(query)
        return !search.isEmpty ? search : (!sanitize(fallback).isEmpty ? sanitize(fallback) : "capture")
    }

    // Four hours leaves over eight minutes of headroom below the classic RIFF limit.
    static func needsRollover(frames: Int64) -> Bool { frames >= 4 * 60 * 60 * 48_000 }

    /// Reserve the next numbered meeting directory. Concurrent recorders cannot claim the same occurrence.
    static func reserve(stem: String, directory: URL, date: Date = Date(), timeZone: TimeZone = .current) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let prefix = stem + "-" + formatter.string(from: date) + "-"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var occurrence = names.filter { $0.hasPrefix(prefix) }.compactMap { name -> Int? in
            let suffix = name.dropFirst(prefix.count)
            return suffix.allSatisfy(\.isNumber) ? Int(suffix) : nil
        }.max() ?? 0
        while occurrence < Int.max {
            occurrence += 1
            let number = occurrence < 10 ? "0" + String(occurrence) : String(occurrence)
            let url = directory.appendingPathComponent(prefix + number, isDirectory: true)
            if mkdir(url.path, 0o700) == 0 { return url }
            guard errno == EEXIST else { throw CaptureError.message("Cannot create meeting directory \(url.path): \(String(cString: strerror(errno)))") }
        }
        throw CaptureError.message("Meeting occurrence limit reached for \(prefix)")
    }
}

struct MicrophoneChoice {
    let device: InputDevice
    let source: String
    let reason: String
}

enum MicrophonePolicy {
    static func choose(explicitUID: String?, devices: [InputDevice], activeAppDevices: Set<UInt32>?, canCapture: (InputDevice) -> Bool) throws -> MicrophoneChoice {
        if let explicitUID {
            guard let device = devices.first(where: { $0.uid == explicitUID }) else { throw CaptureError.message("Microphone not found. Run capture-it devices and choose an input UID.") }
            return MicrophoneChoice(device: device, source: "explicit", reason: "explicit --mic override")
        }
        if let ids = activeAppDevices, ids.count == 1,
           let device = devices.first(where: { ids.contains($0.id) }), canCapture(device) {
            return MicrophoneChoice(device: device, source: "app", reason: "selected app's active input")
        }
        guard let device = devices.first(where: \.isDefault) else { throw CaptureError.message("No system default microphone is available. Run capture-it devices and use --mic.") }
        let why: String
        if activeAppDevices == nil { why = "app input inspection unavailable" }
        else if activeAppDevices!.isEmpty { why = "no active app mic detected" }
        else if activeAppDevices!.count > 1 { why = "multiple active app inputs" }
        else { why = "app input is unavailable to capture" }
        return MicrophoneChoice(device: device, source: "system-default", reason: "system default; \(why)")
    }
}
