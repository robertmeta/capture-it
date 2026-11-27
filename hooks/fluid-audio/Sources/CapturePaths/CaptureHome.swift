import Foundation

/// User-owned recordings and voice samples. The model cache is managed separately.
public struct CaptureHome {
    public let root: URL
    public let voices: URL
    public var recordings: URL { root.appendingPathComponent("recordings", isDirectory: true) }

    public init(override: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                userDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        func directory(_ key: String) -> URL? {
            guard let path = environment[key], !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let selected = override ?? directory("CAPTURE_IT_HOME")
        root = selected ?? userDirectory.appendingPathComponent("Documents/capture-it", isDirectory: true)
        let legacy = userDirectory.appendingPathComponent("Library/Application Support/capture-it/voices")
        if let exact = directory("CAPTURE_IT_VOICES") {
            voices = exact
        } else if selected == nil && FileManager.default.fileExists(atPath: legacy.path) {
            voices = legacy
        } else {
            voices = root.appendingPathComponent("voices", isDirectory: true)
        }
    }
}
