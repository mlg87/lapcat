import Foundation
import LapCatCore

/// Flags mic segments that are the speakers' playback of the other side picked up by the microphone
/// (FR-2.3b): a system segment within ±1.5 s says (nearly) the same thing.
public enum EchoDeduplicator {
    /// A system segment counts when its span, widened by this much on both sides, overlaps the mic segment.
    public static let windowMs = 1_500
    /// Minimum normalized Levenshtein similarity of the normalized texts.
    public static let minimumSimilarity = 0.8

    /// Ids of the mic segments to mark `is_echo_duplicate`.
    public static func flag(micSegments: [Segment], systemSegments: [Segment]) -> [Int64] {
        let system = systemSegments.map { (segment: $0, text: Array(normalize($0.text))) }
        return micSegments.compactMap { mic in
            guard let id = mic.id else { return nil }
            let micText = Array(normalize(mic.text))
            guard !micText.isEmpty else { return nil }
            let isEcho = system.contains { candidate in
                candidate.segment.tStartMs - windowMs <= mic.tEndMs
                    && candidate.segment.tEndMs + windowMs >= mic.tStartMs
                    && similarity(micText, candidate.text) >= minimumSimilarity
            }
            return isEcho ? id : nil
        }
    }

    /// Lowercased, punctuation removed, whitespace collapsed.
    public static func normalize(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
                ? " " : Character(scalar)
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `1 − distance / max(length)`; two empty strings are identical (1.0).
    public static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(a, b)) / Double(longest)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
