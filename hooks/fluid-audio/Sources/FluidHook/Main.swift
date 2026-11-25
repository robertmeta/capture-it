import AVFoundation
@preconcurrency import CoreML
import CryptoKit
import Darwin
import FluidAudio
import FluidHookSupport
import Foundation

private struct ModelSpec: Decodable {
    let repository: String
    let revision: String
    let paths: [String]
}

private struct ModelManifest: Decodable {
    struct File: Decodable { let path: String; let size: Int; let sha256: String }
    let version: Int
    let repository: String
    let revision: String
    let files: [File]
}

@main struct FluidHook {
    static func main() async {
        umask(0o077)
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FluidAudio hook: \(error)\n".utf8)); exit(1) }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let reviewing = arguments.first == "--speakers" && (4...5).contains(arguments.count)
        guard arguments.count == 1 || reviewing else { throw HookFailure("Usage: hooks/fluidaudio EVENT_JSON, or --check. Run make setup-fluid for initial installation.") }
        if arguments[0] == "--help" {
            print("Offline FluidAudio hook: EVENT_JSON → diarization.json and optional speaker-transcript.jsonl/.txt. --check validates installed models. No runtime downloads.")
            return
        }
        let spec = try JSONDecoder().decode(ModelSpec.self, from: Data(contentsOf: Bundle.module.url(forResource: "model-spec", withExtension: "json")!))
        if arguments == ["--people"] {
            let people = try SpeakerReview.references(revision: spec.revision)
            if people.isEmpty { print("No remembered voices") }
            for name in people.keys.sorted() { print("\(name)\t\(people[name]!.count) samples") }
            return
        }
        let directory = modelDirectory()
        if reviewing {
            try await SpeakerReview.review(session: URL(fileURLWithPath: arguments[1]), run: arguments[2],
                                           speaker: arguments[3], name: arguments.count == 5 ? arguments[4] : nil,
                                           revision: spec.revision) {
                _ = try verifyModels(directory: directory, spec: spec)
                let manager = OfflineDiarizerManager()
                manager.initialize(models: try loadModels(directory: directory))
                return manager
            }
            return
        }
        let manifest = try verifyModels(directory: directory, spec: spec)
        if arguments[0] == "--check" {
            print("Offline models ready: \(manifest.repository)@\(manifest.revision), \(manifest.files.count) verified files")
            return
        }
        let inputURL = URL(fileURLWithPath: arguments[0])
        let input = try FluidInput.load(inputURL)
        guard let outputPath = ProcessInfo.processInfo.environment["CAPTURE_IT_HOOK_OUTPUT"], outputPath.hasPrefix("/") else {
            throw HookFailure("Run through capture-it --hook or capture-it hooks; CAPTURE_IT_HOOK_OUTPUT is required")
        }
        let output = URL(fileURLWithPath: outputPath)
        guard output.standardizedFileURL != URL(fileURLWithPath: input.wav).deletingLastPathComponent().standardizedFileURL else {
            throw HookFailure("Use a separate hook output directory, not the original session directory")
        }
        let analysis = output.appendingPathComponent(".analysis-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: analysis) }
        let duration = try AnalysisAudio.prepare(wav: URL(fileURLWithPath: input.wav), destination: analysis)
        let models = try loadModels(directory: directory)
        let manager = OfflineDiarizerManager()
        // Initialize from local MLModels directly. prepareModels() is deliberately
        // unused because its fallback may download or replace assets.
        manager.initialize(models: models)
        let began = ContinuousClock.now
        let result = try await manager.process(analysis)
        let elapsed = began.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let turns = try result.segments.map { segment -> SpeakerTurn in
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            guard start.isFinite, end.isFinite, start >= 0, end >= start, end <= duration + 0.1 else {
                throw HookFailure("Diarizer returned an invalid time range")
            }
            return SpeakerTurn(start: start, end: min(end, duration), speaker: String(describing: segment.speakerId))
        }.sorted { ($0.start, $0.end, $0.speaker) < ($1.start, $1.end, $1.speaker) }
        let references = try SpeakerReview.references(revision: spec.revision)
        var labels: [String: Identity] = [:]
        if !references.isEmpty {
            let examples = voiceExamples(turns)
            for (id, vector) in result.speakerDatabase ?? [:] where examples[id]?.isEmpty == false {
                if let name = VoiceMatching.match(vector, references: references) {
                    labels[id] = Identity(name: name, source: "voice-match")
                }
            }
        }
        try writeJSON(labels, to: output.appendingPathComponent("speaker-identities.json"))
        let names = labels.mapValues(\.name)
        // Keep the anonymous cluster IDs alongside the separate identity evidence.
        let event = try JSONSerialization.jsonObject(with: Data(contentsOf: inputURL)) as! [String: Any]
        struct Report: Encodable {
            let version = 1
            let engine = "FluidAudio offline Community-1/VBx"
            let sourceWav: String
            let modelRepository: String
            let modelRevision: String
            let duration: Double
            let processingSeconds: Double
            let analysisMix = "0.25*app-left + 0.25*app-right + 0.5*microphone; 16000 Hz mono"
            let timebase = "seconds from recording start"
            let speakers: [String]
            let turns: [SpeakerTurn]
        }
        let report = Report(sourceWav: input.wav, modelRepository: spec.repository, modelRevision: spec.revision,
                            duration: duration, processingSeconds: seconds, speakers: Array(Set(turns.map(\.speaker))).sorted(), turns: turns)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var object = try JSONSerialization.jsonObject(with: encoder.encode(report)) as! [String: Any]
        if let meeting = event["meeting"] { object["meeting"] = meeting }
        object["transcriptComplete"] = input.transcriptComplete ?? false
        let rttm = turns.map { "SPEAKER recording 1 \(String(format: "%.3f", $0.start)) \(String(format: "%.3f", $0.end - $0.start)) <NA> <NA> \($0.speaker) <NA> <NA>\n" }.joined()
        try writeArtifact(Data(rttm.utf8), to: output.appendingPathComponent("diarization.rttm"))
        if let segments = input.segments {
            let lines = try String(contentsOfFile: segments, encoding: .utf8).split(separator: "\n")
            var structured = Data()
            var text = ""
            let jsonlEncoder = JSONEncoder(); jsonlEncoder.outputFormatting = [.sortedKeys]
            for line in lines {
                let phrase = try JSONDecoder().decode(TranscriptPhrase.self, from: Data(line.utf8))
                let attributed = try PhraseAttribution.attribute(phrase, turns: turns)
                structured.append(try jsonlEncoder.encode(attributed)); structured.append(10)
                text += PhraseAttribution.line(attributed, names: names)
            }
            try writeArtifact(structured, to: output.appendingPathComponent("speaker-transcript.jsonl"))
            try writeArtifact(Data(text.utf8), to: output.appendingPathComponent("speaker-transcript.txt"))
            object["attribution"] = "phrase overlap only; mixed/unknown preserved; see speaker-identities.json for assigned and voice-matched names"
        }
        // Write the completion artifact last, after every derived artifact succeeds.
        try writeArtifact(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                          to: output.appendingPathComponent("diarization.json"))
        print("Saved \(turns.count) speaker turns (\(Set(turns.map(\.speaker)).count) speakers, \(names.count) voice matches) → \(output.path)")
    }

    private static func modelDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["CAPTURE_IT_FLUID_MODELS"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/capture-it/fluid-models")
    }

    private static func verifyModels(directory: URL, spec: ModelSpec) throws -> ModelManifest {
        let url = directory.appendingPathComponent("setup.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw HookFailure("Offline FluidAudio models are missing. Run make setup-fluid explicitly; recording is retained.") }
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
        guard manifest.version == 1, manifest.repository == spec.repository, manifest.revision == spec.revision else {
            throw HookFailure("Model setup does not match the pinned model revision; choose a new CAPTURE_IT_FLUID_MODELS directory and run setup-fluid")
        }
        for path in spec.paths {
            guard manifest.files.contains(where: { path.hasSuffix("/") ? $0.path.hasPrefix(path) : $0.path == path }) else {
                throw HookFailure("Model setup is missing \(path)")
            }
        }
        for file in manifest.files {
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."), !file.path.contains("\0") else {
                throw HookFailure("Invalid model manifest path")
            }
            let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(file.path))
            defer { try? handle.close() }
            var hash = SHA256(); var size = 0
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data); size += data.count }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard size == file.size, digest == file.sha256 else { throw HookFailure("Model integrity check failed: \(file.path). No download attempted.") }
        }
        return manifest
    }

    private static func loadModels(directory: URL) throws -> OfflineDiarizerModels {
        let all = MLModelConfiguration(); all.computeUnits = .all
        let cpu = MLModelConfiguration(); cpu.computeUnits = .cpuOnly
        func model(_ name: String, _ config: MLModelConfiguration) throws -> MLModel {
            try MLModel(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: config)
        }
        struct Parameters: Decodable {
            struct Tensor: Decodable { let data_base64: String }
            let tensors: [String: Tensor]
        }
        let parameters = try JSONDecoder().decode(Parameters.self, from: Data(contentsOf: directory.appendingPathComponent("plda-parameters.json")))
        guard let encoded = parameters.tensors["psi"]?.data_base64, let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty, bytes.count.isMultiple(of: 4) else { throw HookFailure("Invalid PLDA psi parameters") }
        let psi = stride(from: 0, to: bytes.count, by: 4).map { offset -> Double in
            let word = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return Double(Float(bitPattern: UInt32(littleEndian: word)))
        }
        return try OfflineDiarizerModels(segmentationModel: model("Segmentation", all), fbankModel: model("FBank", cpu),
                                         embeddingModel: model("Embedding", all), pldaRhoModel: model("PldaRho", all),
                                         pldaPsi: psi, compilationDuration: 0)
    }
}
