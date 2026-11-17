import AVFoundation
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

    static func output(query: String, appName: String, directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath), date: Date = Date(), timeZone: TimeZone = .current) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = stem(query, fallback: appName) + "-" + formatter.string(from: date)
        var path = directory.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: path.path) {
            path = directory.appendingPathComponent("\(name)-\(suffix)")
            suffix += 1
        }
        return path
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
