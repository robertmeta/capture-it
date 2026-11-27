import AppKit
import Darwin
import Foundation

struct AppChoice: Equatable, Sendable {
    let name: String
    let bundleID: String
    let pid: pid_t
    var runningPID: pid_t? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }.map(\.processIdentifier)
        return running.contains(pid) ? pid : (running.count == 1 ? running[0] : nil)
    }
    var label: String { pid > 0 ? "\(name) (\(bundleID), pid \(pid))" : "\(name) (\(bundleID), waiting for launch)" }
}

enum AppSelection {
    @MainActor static func running() -> [AppChoice] {
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy != .prohibited && $0.bundleIdentifier?.isEmpty == false
        }
        return applications.filter { app in
            guard let path = app.bundleURL?.path else { return true }
            // Embedded helper bundles belong to their containing app, rather
            // than being choices such as Teams WebView and Teams Renderer.
            return !applications.contains { other in
                guard other.processIdentifier != app.processIdentifier, let parent = other.bundleURL?.path else { return false }
                return path.hasPrefix(parent + "/Contents/")
            }
        }.compactMap { app in
            guard let bundle = app.bundleIdentifier else { return nil }
            return AppChoice(name: app.localizedName ?? bundle, bundleID: bundle, pid: app.processIdentifier)
        }
    }

    static func matches(_ query: String, in applications: [AppChoice]) throws -> [AppChoice] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw CaptureError.message("--app needs an app name, bundle identifier or wildcard") }
        let wildcard = query.contains("*") || query.contains("?")
        let sorted = applications.sorted {
            let names = $0.name.localizedCaseInsensitiveCompare($1.name)
            return names == .orderedSame ? ($0.bundleID, $0.pid) < ($1.bundleID, $1.pid) : names == .orderedAscending
        }
        if !wildcard {
            let exact = sorted.filter { $0.bundleID.caseInsensitiveCompare(query) == .orderedSame }
            if !exact.isEmpty { return exact }
            return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
        }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: query)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return sorted.filter { app in
            [app.name, app.bundleID].contains { value in
                expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            }
        }
    }

    static func choose(_ query: String, from applications: [AppChoice], interactive: Bool,
                       read: () -> String?, write: (String) -> Void) throws -> AppChoice {
        let choices = try matches(query, in: applications)
        guard !choices.isEmpty else { throw CaptureError.message("No running app matches '\(query)'. Open the app and try again.") }
        if choices.count == 1 {
            write("Selected \(choices[0].label)\n")
            return choices[0]
        }
        write("Several apps match '\(query)':\n")
        for (index, app) in choices.enumerated() { write("  \(index + 1). \(app.label)\n") }
        guard interactive else {
            throw CaptureError.message("App selection requires an interactive terminal. Use an exact bundle identifier to select one match.")
        }
        while true {
            write("Choose 1-\(choices.count) (q to cancel): ")
            guard let answer = read()?.trimmingCharacters(in: .whitespacesAndNewlines), answer.lowercased() != "q" else {
                throw CaptureError.message("App selection cancelled")
            }
            if let number = Int(answer), choices.indices.contains(number - 1) { return choices[number - 1] }
            write("Enter a number from 1 to \(choices.count), or q to cancel.\n")
        }
    }

    static func resolve(_ query: String) async throws -> AppChoice {
        var applications = await running()
        if try matches(query, in: applications).isEmpty {
            let files = FileManager.default
            let roots = files.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
            for root in roots where files.fileExists(atPath: root.path) {
                let installed = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                for url in installed where url.pathExtension == "app" {
                    guard let bundle = Bundle(url: url)?.bundleIdentifier,
                          !applications.contains(where: { $0.bundleID == bundle }) else { continue }
                    applications.append(AppChoice(name: url.deletingPathExtension().lastPathComponent, bundleID: bundle, pid: 0))
                }
            }
        }
        return try choose(query, from: applications, interactive: isatty(STDIN_FILENO) == 1,
                          read: { readLine() }, write: { FileHandle.standardError.write(Data($0.utf8)) })
    }
}
