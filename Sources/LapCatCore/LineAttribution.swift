import Foundation

/// Who wrote a line of an enhanced note: the user (it matches a raw-note line) or the AI.
public enum LineKind: String, Sendable, Hashable {
    case mine, ai
}

/// Colors enhanced notes by matching each line against the user's raw notes (no LLM-side markup).
public enum LineAttribution {
    /// One kind per line of `enhanced` (split on `\n`). A line is `.mine` when its normalized text
    /// equals the normalized text of some raw-note line; blank lines are `.ai`.
    public static func classify(enhanced: String, raw: String) -> [LineKind] {
        let mine = Set(raw.split(separator: "\n").map { normalize(String($0)) }.filter { !$0.isEmpty })
        return enhanced.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let normalized = normalize(Citations.replacing(in: String(line)) { _ in "" })
            return !normalized.isEmpty && mine.contains(normalized) ? .mine : .ai
        }
    }

    /// Lowercased, leading list/checkbox markers (`- * • [ ] x` and whitespace) stripped, runs of
    /// whitespace collapsed to one space.
    static func normalize(_ line: String) -> String {
        let lowered = line.lowercased()
        let body = lowered.drop { $0.isWhitespace || leadingMarkers.contains($0) }
        return body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let leadingMarkers: Set<Character> = ["-", "*", "•", "[", "]", "x"]
}
