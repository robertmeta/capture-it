import Foundation

/// An unconfirmed name proposal tied to one analysis and exact transcript evidence.
public struct SpeakerSuggestion: Decodable {
    public struct Evidence: Decodable {
        public let phraseIndex: Int
        public let start: Double
        public let end: Double
        public let quote: String
        public let speakers: [String]
        public let attribution: String
    }
    public let version: Int
    public let id: String
    public let analysisRun: String
    public let speaker: String
    public let name: String
    public let confidence: String
    public let reason: String
    public let evidence: [Evidence]

    /// Recheck persisted proposals against current phrases before displaying them.
    public func validate(run: String, phrases: [AttributedPhrase], speakers: [String]) throws {
        func safe(_ text: String, limit: Int, multiline: Bool = false) -> Bool {
            text.count <= limit && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || (multiline && ($0 == "\n" || $0 == "\t")) }
        }
        guard version == 1, analysisRun == run, speakers.contains(speaker),
              id.count == 64, id.allSatisfy({ $0.isHexDigit }),
              safe(name, limit: 200), safe(reason, limit: 4000, multiline: true),
              ["high", "medium", "low"].contains(confidence), (1...12).contains(evidence.count) else {
            throw HookFailure("Invalid or stale speaker suggestion")
        }
        for item in evidence {
            guard phrases.indices.contains(item.phraseIndex), safe(item.quote, limit: 4000, multiline: true) else {
                throw HookFailure("Speaker suggestion has invalid evidence")
            }
            let original = phrases[item.phraseIndex]
            guard item.start == original.phrase.start, item.end == original.phrase.start + original.phrase.duration,
                  original.phrase.text.contains(item.quote), item.speakers == original.speakers,
                  item.attribution == original.attribution else { throw HookFailure("Speaker suggestion evidence differs from saved transcript") }
        }
        guard evidence.contains(where: { $0.quote.localizedCaseInsensitiveContains(name) }) else {
            throw HookFailure("Speaker name does not occur in the cited evidence")
        }
        guard evidence.contains(where: { $0.speakers == [speaker] && $0.attribution == "single-speaker-overlap" }) else {
            throw HookFailure("Speaker suggestion lacks evidence attributed to the proposed voice")
        }
    }
}
