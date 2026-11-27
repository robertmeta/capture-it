import CapturePaths
import AVFoundation
import FluidAudio
import FluidHookSupport
import Foundation

extension SpeakerReview {
    private struct MatchSample: Encodable {
        let start: Double
        let end: Double
        let embedding: [Float]?
        let assessment: VoiceMatching.Assessment
    }
    private struct MatchEntry: Encodable {
        let speaker: String
        let status: String
        let name: String?
        let samples: [MatchSample]
    }
    private struct MatchReport: Encodable {
        let version = 1
        let sourceAudio: String
        let analysisRun: String
        let modelRevision: String
        let referenceLibrary: String
        let excludedSession: String
        let referenceNames: Int
        let referenceSamples: Int
        let startedAt: String
        var complete = false
        var entries: [MatchEntry] = []
    }

    /// Compare saved isolated turns against remembered voices from other sessions.
    static func rematch(session: URL, output: URL, wav: URL, speakers: [String], turns: [SpeakerTurn], revision: String,
                        makeManager: () throws -> OfflineDiarizerManager) async throws {
        let files = FileManager.default
        let identitiesURL = output.appendingPathComponent("speaker-identities.json")
        let named = files.fileExists(atPath: identitiesURL.path)
            ? try JSONDecoder().decode([String: Identity].self, from: Data(contentsOf: identitiesURL)) : [:]
        let unknown = speakers.filter { named[$0] == nil }.sorted()
        let references = try references(revision: revision, excluding: session)
        let examples = voiceExamples(turns)
        let audio = try AVAudioFile(forReading: wav)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard turns.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration }) else {
            throw HookFailure("Saved speaker turns exceed the source audio")
        }
        let reports = output.appendingPathComponent("voice-matches")
        try files.createDirectory(at: reports, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = reports.appendingPathComponent(UUID().uuidString + ".json")
        var report = MatchReport(sourceAudio: wav.path, analysisRun: output.deletingLastPathComponent().lastPathComponent + "/" + output.lastPathComponent,
                                 modelRevision: revision, referenceLibrary: CaptureHome().voices.path, excludedSession: session.standardizedFileURL.path,
                                 referenceNames: references.count, referenceSamples: references.values.reduce(0) { $0 + $1.count },
                                 startedAt: ISO8601DateFormatter().string(from: Date()))
        func persist() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: destination, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        try persist()
        var manager: OfflineDiarizerManager?
        for speaker in unknown {
            var samples: [MatchSample] = []
            if !references.isEmpty {
                for span in examples[speaker] ?? [] {
                    let current = try manager ?? makeManager()
                    manager = current
                    let clip = files.temporaryDirectory.appendingPathComponent("capture-it-match-\(UUID().uuidString).wav")
                    defer { try? files.removeItem(at: clip) }
                    try AnalysisAudio.prepare(wav: wav, destination: clip, interval: span)
                    let vector = try await embedding(clip, manager: current)
                    samples.append(MatchSample(start: span.lowerBound, end: span.upperBound, embedding: vector,
                                               assessment: VoiceMatching.assess(vector ?? [], references: references)))
                }
            }
            let name = VoiceMatching.consensus(samples.map(\.assessment))
            let status: String
            if let name { status = try saveMatch(name, speaker: speaker, output: output) ? "matched" : "existing-name-preserved" }
            else if references.isEmpty { status = "no-references" }
            else if samples.isEmpty { status = "no-isolated-sample" }
            else if Set(samples.compactMap { $0.assessment.name }).count > 1 { status = "conflicting-samples" }
            else if samples.contains(where: { $0.assessment.reason == "ambiguous" }) { status = "ambiguous" }
            else { status = "insufficient-agreement" }
            report.entries.append(MatchEntry(speaker: speaker, status: status, name: name, samples: samples))
            try persist()
        }
        report.complete = true
        try persist()
        let matched = report.entries.filter { $0.status == "matched" }.count
        print("Voice matching: \(matched) newly named, \(unknown.count - matched) unresolved or preserved, \(named.count) existing names retained.")
        print("Match report: \(destination.path)")
    }
}
