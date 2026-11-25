import AVFoundation
import CryptoKit
import Darwin
import FluidAudio
import FluidHookSupport
import Foundation

struct Identity: Codable {
    let name: String
    let source: String
}

private struct Enrollment: Codable {
    var name: String
    let revision: String
    let embeddings: [[Float]]
}

enum SpeakerReview {
    private static var files: FileManager { .default }
    private static var library: URL {
        if let path = ProcessInfo.processInfo.environment["CAPTURE_IT_VOICES"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/capture-it/voices")
    }

    static func references(revision: String) throws -> [String: [[Float]]] {
        var people: [String: [[Float]]] = [:]
        let entries: [URL]
        do { entries = try files.contentsOfDirectory(at: library, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
        for entry in entries where entry.pathExtension == "voice" {
            let data = try Data(contentsOf: entry.appendingPathComponent("profile.json"))
            let profile = try JSONDecoder().decode(Enrollment.self, from: data)
            if profile.revision == revision {
                people[profile.name, default: []] += profile.embeddings.compactMap(VoiceMatching.normalized)
            }
        }
        return people
    }

    private struct Report: Decodable {
        let version: Int
        let speakers: [String]
        let turns: [SpeakerTurn]
    }

    private static func select(session: URL, run: String) throws -> URL {
        let root = session.appendingPathComponent("hooks")
        let missing = HookFailure("No completed speaker analysis. Run capture-it hooks on this session with FluidAudio enabled.")
        guard files.fileExists(atPath: root.path) else { throw missing }
        var candidates = [String: URL]()
        for parent in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where UUID(uuidString: parent.lastPathComponent) != nil {
            for output in try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                where output.lastPathComponent.allSatisfy(\.isNumber) {
                if files.fileExists(atPath: output.appendingPathComponent("diarization.json").path) {
                    candidates[parent.lastPathComponent + "/" + output.lastPathComponent] = output
                }
            }
        }
        if !run.isEmpty, let selected = candidates[run] { return selected }
        if run.isEmpty, candidates.count == 1 { return candidates.values.first! }
        guard !candidates.isEmpty else { throw missing }
        throw HookFailure("Select a speaker analysis with --run followed by one of: " + candidates.keys.sorted().joined(separator: ", "))
    }

    private static func identities(in output: URL) throws -> [String: Identity] {
        let url = output.appendingPathComponent("speaker-identities.json")
        guard files.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: Identity].self, from: Data(contentsOf: url))
    }

    static func review(session: URL, run: String, speaker: String, name: String?, revision: String,
                       makeManager: () throws -> OfflineDiarizerManager) async throws {
        let output = try select(session: session, run: run)
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: output.appendingPathComponent("diarization.json")))
        guard report.version == 1 else { throw HookFailure("Unsupported diarization report version") }
        let examples = voiceExamples(report.turns)
        if speaker.isEmpty && name == nil {
            let labels = try identities(in: output)
            for id in report.speakers {
                let times = (examples[id] ?? []).map { String(format: "%.2f–%.2fs", $0.lowerBound, $0.upperBound) }
                print("\(id)\t\(labels[id]?.name ?? "(unnamed)")\t\(times.isEmpty ? "no isolated sample" : times.joined(separator: ", "))")
            }
            if report.speakers.isEmpty { print("No speakers detected") }
            return
        }
        guard report.speakers.contains(speaker) else { throw HookFailure("Unknown speaker ID. List speakers first.") }
        let spans = examples[speaker] ?? []
        let wav = session.appendingPathComponent("recording.wav")
        if let name {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.rangeOfCharacter(from: .controlCharacters) == nil else { throw HookFailure("Enter a nonempty, single-line name") }
            // Serialize enrollment and its transcript projection across concurrent CLI invocations on this run.
            let fd = open(output.path, O_RDONLY)
            guard fd >= 0 else { throw HookFailure("Cannot open speaker analysis directory") }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw HookFailure("Cannot lock speaker analysis") }
            let key = [output.deletingLastPathComponent().lastPathComponent, output.lastPathComponent, speaker].joined(separator: "/")
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let destination = library.appendingPathComponent(digest + ".voice")
            if !spans.isEmpty {
                try await enroll(clean, wav: wav, spans: spans, destination: destination, revision: revision, makeManager: makeManager)
            }
            var labels = try identities(in: output)
            labels[speaker] = Identity(name: clean, source: "assigned")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(labels).write(to: output.appendingPathComponent("speaker-identities.json"), options: .atomic)
            let jsonl = output.appendingPathComponent("speaker-transcript.jsonl")
            if files.fileExists(atPath: jsonl.path) {
                let names = labels.mapValues(\.name)
                let lines = try String(contentsOf: jsonl, encoding: .utf8).split(separator: "\n")
                var text = ""
                for line in lines {
                    let phrase = try JSONDecoder().decode(AttributedPhrase.self, from: Data(line.utf8))
                    guard phrase.phrase.start.isFinite, phrase.phrase.start >= 0, phrase.phrase.start < Double(Int.max) else {
                        throw HookFailure("Invalid phrase timestamp in speaker-transcript.jsonl")
                    }
                    text += PhraseAttribution.line(phrase, names: names)
                }
                try Data(text.utf8).write(to: output.appendingPathComponent("speaker-transcript.txt"), options: .atomic)
            }
            print("\(speaker) → \(clean)")
            print(spans.isEmpty ? "Assigned in this recording only. Enrollment needs two seconds of isolated speech." : "Voice samples: \(destination.path)")
        } else {
            guard let first = spans.first else { throw HookFailure("No isolated two-second voice sample to play.") }
            let temp = files.temporaryDirectory.appendingPathComponent("capture-it-\(UUID().uuidString).wav")
            defer { try? files.removeItem(at: temp) }
            try AnalysisAudio.prepare(wav: wav, destination: temp, interval: first)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [temp.path]
            try player.run()
            player.waitUntilExit()
            guard player.terminationStatus == 0 else { throw HookFailure("Voice sample playback failed") }
        }
    }

    private static func enroll(_ name: String, wav: URL, spans: [Range<Double>], destination: URL,
                               revision: String, makeManager: () throws -> OfflineDiarizerManager) async throws {
        let profileURL = destination.appendingPathComponent("profile.json")
        if files.fileExists(atPath: profileURL.path) {
            var profile = try JSONDecoder().decode(Enrollment.self, from: Data(contentsOf: profileURL))
            if profile.revision == revision {
                profile.name = name
                try JSONEncoder().encode(profile).write(to: profileURL, options: .atomic)
                return
            }
            throw HookFailure("Enrollment uses an older model. Run a fresh speaker analysis before enrolling again.")
        }
        let manager = try makeManager()
        try files.createDirectory(at: library, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = library.appendingPathComponent(".enrollment-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { if files.fileExists(atPath: staging.path) { try? files.removeItem(at: staging) } }
        var vectors: [[Float]] = []
        for (index, span) in spans.enumerated() {
            let clip = staging.appendingPathComponent("sample-\(index + 1).wav")
            try AnalysisAudio.prepare(wav: wav, destination: clip, interval: span)
            let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: clip, targetSampleRate: 16_000)
            defer { source.cleanup() }
            let seconds = Double(source.sampleCount) / 16_000
            let embedded = try await manager.embedSpans(audioSource: source, spans: [0..<seconds])
            guard let raw = embedded.first, let vector = VoiceMatching.normalized(raw) else { throw HookFailure("Voice sample has no usable embedding") }
            vectors.append(vector)
        }
        try writeJSON(Enrollment(name: name, revision: revision, embeddings: vectors), to: staging.appendingPathComponent("profile.json"))
        try files.moveItem(at: staging, to: destination)
    }
}
