import CapturePaths
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
    private static var library: URL { CaptureHome().voices }

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

    static func review(session: URL, run: String, interactive: Bool, speaker: String, name: String?, revision: String,
                       makeManager: () throws -> OfflineDiarizerManager) async throws -> Bool {
        let output = try select(session: session, run: run)
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: output.appendingPathComponent("diarization.json")))
        guard report.version == 1 else { throw HookFailure("Unsupported diarization report version") }
        let examples = voiceExamples(report.turns, minimumDuration: 0.05)
        let suggestions = try SuggestionReview.load(session: session, output: output, speakers: report.speakers)
        struct SessionFiles: Decodable {
            struct Chunk: Decodable { let file: String }
            let chunks: [Chunk]
        }
        let saved = try JSONDecoder().decode(SessionFiles.self, from: Data(contentsOf: session.appendingPathComponent("session.json")))
        guard saved.chunks.count == 1, let file = saved.chunks.first?.file, ["wav", "m4a", "mp3", "aif", "aiff", "caf"].contains(URL(fileURLWithPath: file).pathExtension.lowercased()),
              URL(fileURLWithPath: file).lastPathComponent == file else { throw HookFailure("Expected one session audio filename") }
        let wav = session.appendingPathComponent(file)
        if interactive {
            let terminal = try SpeakerTerminal()
            let matched = try identities(in: output)
            let unknown = report.speakers.filter { matched[$0] == nil }.sorted {
                let a = suggestions[$0]?.isEmpty == false, b = suggestions[$1]?.isEmpty == false
                return a == b ? $0 < $1 : a
            }
            if unknown.isEmpty {
                print(report.speakers.isEmpty ? "No speakers detected." : "All speakers already have names.")
                return true
            }
            var finished = true
            var manager: OfflineDiarizerManager?
            print("Reviewing \(unknown.count) unnamed speaker(s). Enter skips one. :quit or Ctrl-C ends review.")
            for id in unknown {
                guard !terminal.cancelled else { finished = false; break }
                guard let spans = examples[id], let first = spans.first else {
                    print("\(id) has no isolated sample. Use --assign to name this speaker manually.")
                    continue
                }
                let references = try references(revision: revision)
                if !references.isEmpty, first.upperBound - first.lowerBound >= 2 {
                    let current = try manager ?? makeManager()
                    manager = current
                    let clip = files.temporaryDirectory.appendingPathComponent("capture-it-\(UUID()).wav")
                    defer { try? files.removeItem(at: clip) }
                    try AnalysisAudio.prepare(wav: wav, destination: clip, interval: first)
                    if let vector = try await embedding(clip, manager: current),
                       let name = VoiceMatching.match(vector, references: references) {
                        try saveMatch(name, speaker: id, output: output)
                        continue
                    }
                }
                print("Playing \(id)…")
                try play(wav: wav, span: first, terminal: terminal)
                guard !terminal.cancelled, let answer = try SuggestionReview.ask(speaker: id, proposals: suggestions[id] ?? [], output: output, terminal: terminal) else { finished = false; break }
                if answer.name.isEmpty { continue }
                try await assign(answer.name, speaker: id, output: output, wav: wav, spans: spans, revision: revision, makeManager: makeManager)
                if let accepted = answer.accepted { try SuggestionReview.decide([accepted], status: "accepted", output: output) }
                else { try SuggestionReview.decide(suggestions[id] ?? [], status: "replaced", output: output) }
            }
            print("Review finished. You can resume with capture-it speakers and this session path.")
            return finished && !terminal.cancelled
        }
        if speaker.isEmpty && name == nil {
            let labels = try identities(in: output)
            for id in report.speakers {
                let times = (examples[id] ?? []).map { String(format: "%.2f–%.2fs", $0.lowerBound, $0.upperBound) }
                print("\(id)\t\(labels[id]?.name ?? "(unnamed)")\t\(times.isEmpty ? "no isolated sample" : times.joined(separator: ", "))")
                if labels[id] == nil { SuggestionReview.describe(suggestions[id] ?? []) }
            }
            if report.speakers.isEmpty { print("No speakers detected") }
            return true
        }
        guard report.speakers.contains(speaker) else { throw HookFailure("Unknown speaker ID. List speakers first.") }
        let spans = examples[speaker] ?? []
        if let name {
            try await assign(name, speaker: speaker, output: output, wav: wav, spans: spans, revision: revision, makeManager: makeManager)
        } else {
            guard let first = spans.first else { throw HookFailure("No isolated voice sample to play.") }
            try play(wav: wav, span: first)
        }
        return true
    }

    private static func assign(_ name: String, speaker: String, output: URL, wav: URL, spans: [Range<Double>],
                               revision: String, makeManager: () throws -> OfflineDiarizerManager) async throws {
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
        let enrollmentSpans = spans.filter { $0.upperBound - $0.lowerBound >= 2 }
        if !enrollmentSpans.isEmpty {
            try await enroll(clean, wav: wav, spans: enrollmentSpans, destination: destination, revision: revision, makeManager: makeManager)
        }
        try writeIdentity(Identity(name: clean, source: "assigned"), speaker: speaker, output: output)
        print("\(speaker) → \(clean)")
        print(enrollmentSpans.isEmpty ? "Assigned in this recording only. Enrollment needs two seconds of isolated speech." : "Voice samples: \(destination.path)")
    }

    private static func saveMatch(_ name: String, speaker: String, output: URL) throws {
        let fd = open(output.path, O_RDONLY)
        guard fd >= 0 else { throw HookFailure("Cannot open speaker analysis directory") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw HookFailure("Cannot lock speaker analysis") }
        try writeIdentity(Identity(name: name, source: "voice-match"), speaker: speaker, output: output)
    }

    // The caller holds the analysis directory lock while updating both projections.
    private static func writeIdentity(_ identity: Identity, speaker: String, output: URL) throws {
        var labels = try identities(in: output)
        if identity.source == "voice-match", labels[speaker] != nil { return }
        labels[speaker] = identity
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
    }

    private static func embedding(_ clip: URL, manager: OfflineDiarizerManager) async throws -> [Float]? {
        let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: clip, targetSampleRate: 16_000)
        defer { source.cleanup() }
        let seconds = Double(source.sampleCount) / 16_000
        let embedded = try await manager.embedSpans(audioSource: source, spans: [0..<seconds])
        return embedded.first.flatMap(VoiceMatching.normalized)
    }

    private static func play(wav: URL, span: Range<Double>, terminal: SpeakerTerminal? = nil) throws {
        let temp = files.temporaryDirectory.appendingPathComponent("capture-it-\(UUID().uuidString).wav")
        defer { try? files.removeItem(at: temp) }
        try AnalysisAudio.prepare(wav: wav, destination: temp, interval: span)
        let player = try AVAudioPlayer(contentsOf: temp)
        guard player.play() else { throw HookFailure("Voice sample playback failed") }
        defer { player.stop() }
        while player.isPlaying && terminal?.cancelled != true { Thread.sleep(forTimeInterval: 0.05) }
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
            guard let vector = try await embedding(clip, manager: manager) else { throw HookFailure("Voice sample has no usable embedding") }
            vectors.append(vector)
        }
        try writeJSON(Enrollment(name: name, revision: revision, embeddings: vectors), to: staging.appendingPathComponent("profile.json"))
        try files.moveItem(at: staging, to: destination)
    }
}
