import Foundation

/// Pick up to three distinct intervals with only one active speaker, longest first.
/// The model gets at least two seconds of speech and a maximum of eight per clip.
public func voiceExamples(_ turns: [SpeakerTurn]) -> [String: [Range<Double>]] {
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
        let eligible = intervals.filter { $0.upperBound - $0.lowerBound >= 2 }
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
    public static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == 256 else { return nil }
        let length = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard length.isFinite, length > 0 else { return nil }
        return vector.map { Float(Double($0) / length) }
    }

    /// References must be unit vectors returned by normalized(_:).
    public static func match(_ embedding: [Float], references: [String: [[Float]]]) -> String? {
        guard let query = normalized(embedding) else { return nil }
        let ranked = references.compactMap { name, examples -> (name: String, score: Float)? in
            let score = examples.filter { $0.count == query.count }.map { example in
                zip(query, example).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            }.max()
            return score.map { (name, $0) }
        }.sorted { $0.score > $1.score }
        guard let best = ranked.first, best.score >= 0.70,
              ranked.count == 1 || best.score - ranked[1].score >= 0.10 else { return nil }
        return best.name
    }
}
