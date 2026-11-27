import Foundation

/// Pick up to three distinct intervals with only one active speaker, longest first.
/// Enrollment requires two seconds. Playback may request shorter clips.
public func voiceExamples(_ turns: [SpeakerTurn], minimumDuration: Double = 2) -> [String: [Range<Double>]] {
    struct Edge { let time: Double; let id: String; let delta: Int }
    let edges = turns.filter { $0.start >= 0 && $0.end.isFinite && $0.end > $0.start }.flatMap {
        [Edge(time: $0.start, id: $0.speaker, delta: 1), Edge(time: $0.end, id: $0.speaker, delta: -1)]
    }.sorted { $0.time < $1.time }
    var active: [String: Int] = [:]
    var spans: [String: [Range<Double>]] = [:]
    var previous = 0.0
    for edge in edges {
        if previous < edge.time, active.count == 1, let id = active.keys.first {
            if let last = spans[id]?.last, last.upperBound == previous {
                spans[id]?.removeLast()
                spans[id, default: []].append(last.lowerBound..<edge.time)
            } else {
                spans[id, default: []].append(previous..<edge.time)
            }
        }
        active[edge.id, default: 0] += edge.delta
        if active[edge.id] == 0 { active.removeValue(forKey: edge.id) }
        previous = edge.time
    }
    return spans.mapValues { intervals in
        let eligible = intervals.filter { $0.upperBound - $0.lowerBound >= minimumDuration }
        let longest = eligible.sorted { left, right in
            let a = left.upperBound - left.lowerBound
            let b = right.upperBound - right.lowerBound
            return a == b ? left.lowerBound < right.lowerBound : a > b
        }
        return longest.prefix(3).map { span in
            let start = span.lowerBound + max(0, (span.upperBound - span.lowerBound - 8) / 2)
            return start..<min(span.upperBound, start + 8)
        }
    }
}

/// Compare only compatible model embeddings and require separation from other people.
public enum VoiceMatching {
    /// A local similarity decision, including the strongest alternative for audit.
    public struct Assessment: Codable, Sendable {
        public let name: String?
        public let candidate: String?
        public let score: Float?
        public let runnerUpScore: Float?
        public let reason: String
    }
    public static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == 256 else { return nil }
        let length = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard length.isFinite, length > 0 else { return nil }
        return vector.map { Float(Double($0) / length) }
    }

    /// References must be unit vectors returned by normalized(_:).
    public static func match(_ embedding: [Float], references: [String: [[Float]]]) -> String? {
        assess(embedding, references: references).name
    }

    /// Require the existing 0.70 similarity and 0.10 separation between people.
    public static func assess(_ embedding: [Float], references: [String: [[Float]]]) -> Assessment {
        guard let query = normalized(embedding) else {
            return Assessment(name: nil, candidate: nil, score: nil, runnerUpScore: nil, reason: "invalid-embedding")
        }
        let ranked = references.compactMap { name, examples -> (name: String, score: Float)? in
            let score = examples.filter { $0.count == query.count }.map { example in
                zip(query, example).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            }.max()
            return score.map { (name, $0) }
        }.sorted { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }
        guard let best = ranked.first else {
            return Assessment(name: nil, candidate: nil, score: nil, runnerUpScore: nil, reason: "no-references")
        }
        let next = ranked.dropFirst().first?.score
        let reason = best.score < 0.70 ? "weak" : (next.map { best.score - $0 < 0.10 } == true ? "ambiguous" : "matched")
        return Assessment(name: reason == "matched" ? best.name : nil, candidate: best.name,
                          score: best.score, runnerUpScore: next, reason: reason)
    }

    /// A strict majority must agree, with no positively matched conflicting name.
    public static func consensus(_ samples: [Assessment]) -> String? {
        let names = samples.compactMap(\.name)
        guard let name = names.first, Set(names).count == 1, names.count > samples.count / 2 else { return nil }
        return name
    }
}
