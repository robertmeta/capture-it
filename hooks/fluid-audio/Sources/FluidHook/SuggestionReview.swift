import CryptoKit
import Darwin
import FluidHookSupport
import Foundation

/// Suggestions are read-only proposals. Only the normal confirmed assignment enrolls a voice.
enum SuggestionReview {
    private struct Completion: Decodable {
        let version: Int
        let status: String
        let analysisRun: String?
        let transcriptSha256: String?
    }
    private struct Results: Decodable {
        struct Item: Decodable { let status: String; let outputDirectory: String }
        let results: [Item]
    }

    static func load(session: URL, output: URL, speakers: [String]) throws -> [String: [SpeakerSuggestion]] {
        let files = FileManager.default
        let transcript = output.appendingPathComponent("speaker-transcript.jsonl")
        guard files.fileExists(atPath: transcript.path) else { return [:] }
        let data = try Data(contentsOf: transcript)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let phrases = try data.split(separator: 10).map { try JSONDecoder().decode(AttributedPhrase.self, from: Data($0)) }
        let run = output.deletingLastPathComponent().lastPathComponent + "/" + output.lastPathComponent
        let decisions = try savedDecisions(output: output)
        let root = session.appendingPathComponent("hooks")
        var byID: [String: SpeakerSuggestion] = [:]
        for parent in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where UUID(uuidString: parent.lastPathComponent) != nil {
            let result = parent.appendingPathComponent("result.json")
            guard files.fileExists(atPath: result.path) else { continue }
            for item in try JSONDecoder().decode(Results.self, from: Data(contentsOf: result)).results where item.status == "complete" {
                let directory = URL(fileURLWithPath: item.outputDirectory).standardizedFileURL
                guard directory.deletingLastPathComponent() == parent else { continue }
                let marker = directory.appendingPathComponent("enrichment.json")
                guard files.fileExists(atPath: marker.path) else { continue }
                do {
                    let meta = try JSONDecoder().decode(Completion.self, from: Data(contentsOf: marker))
                    guard meta.version == 1, meta.status == "complete", meta.analysisRun == run, meta.transcriptSha256 == digest else { continue }
                    let proposals = try String(contentsOf: directory.appendingPathComponent("speaker-suggestions.jsonl"), encoding: .utf8)
                    for line in proposals.split(separator: "\n") {
                        let value = try JSONDecoder().decode(SpeakerSuggestion.self, from: Data(line.utf8))
                        try value.validate(run: run, phrases: phrases, speakers: speakers)
                        if decisions[value.id] == nil { byID[value.id] = value }
                    }
                } catch {
                    FileHandle.standardError.write(Data("Ignoring invalid AI suggestions at \(directory.path): \(error)\n".utf8))
                }
            }
        }
        let rank = ["high": 0, "medium": 1, "low": 2]
        return Dictionary(grouping: byID.values, by: \.speaker).mapValues { values in
            values.sorted { (rank[$0.confidence] ?? 3, $0.name, $0.id) < (rank[$1.confidence] ?? 3, $1.name, $1.id) }
        }
    }

    static func describe(_ proposals: [SpeakerSuggestion]) {
        func line(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ") }
        for (index, value) in proposals.enumerated() {
            print("Suggestion \(index + 1): \(value.name) (\(value.confidence)) — \(line(value.reason))")
            for item in value.evidence {
                print(String(format: "  At %.2fs: “%@”", item.start, line(item.quote)))
            }
        }
    }

    struct Answer { let name: String; let accepted: SpeakerSuggestion? }

    static func ask(speaker: String, proposals: [SpeakerSuggestion], output: URL, terminal: SpeakerTerminal) throws -> Answer? {
        var remaining = proposals
        describe(remaining)
        while !terminal.cancelled {
            if !remaining.isEmpty { print("Type :accept NUMBER to confirm, :reject to dismiss suggestions, a name to change, Enter to skip, or :quit.") }
            guard let answer = try terminal.name(for: speaker), answer != ":quit" else { return nil }
            if answer == ":reject", !remaining.isEmpty {
                try decide(remaining, status: "rejected", output: output)
                remaining = []
                print("Suggestions rejected. Enter a name or skip.")
                continue
            }
            if answer == ":accept" || answer.hasPrefix(":accept ") {
                let number = answer == ":accept" && remaining.count == 1 ? 1 : Int(answer.dropFirst(8))
                guard let number, remaining.indices.contains(number - 1) else {
                    print("Choose the number of a displayed suggestion.")
                    continue
                }
                let accepted = remaining[number - 1]
                return Answer(name: accepted.name, accepted: accepted)
            }
            if answer.hasPrefix(":") && answer != "" {
                print("Use a name, :accept NUMBER, :reject, Enter, or :quit.")
                continue
            }
            return Answer(name: answer, accepted: nil)
        }
        return nil
    }

    private static func savedDecisions(output: URL) throws -> [String: String] {
        let url = output.appendingPathComponent("speaker-suggestion-decisions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    static func decide(_ proposals: [SpeakerSuggestion], status: String, output: URL) throws {
        let fd = open(output.path, O_RDONLY)
        guard fd >= 0 else { throw HookFailure("Cannot open speaker suggestion decisions") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw HookFailure("Cannot lock speaker suggestion decisions") }
        var decisions = try savedDecisions(output: output)
        for proposal in proposals { decisions[proposal.id] = status }
        let data = try JSONEncoder().encode(decisions)
        let url = output.appendingPathComponent("speaker-suggestion-decisions.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
