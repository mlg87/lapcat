import Foundation

/// Renders a meeting transcript for LLM prompts: one line per segment,
/// `[<segment id>] <hh:mm:ss> <speaker>: <text>`, which is what `[[s:ID]]` citations refer to.
public enum TranscriptFormatter {
    public static func forLLM(segments: [Segment], participants: [Participant]) -> String {
        lines(segments: segments, participants: participants).joined(separator: "\n")
    }

    /// The `forLLM` lines, unjoined (callers truncating to a budget drop from the front).
    public static func lines(segments: [Segment], participants: [Participant]) -> [String] {
        let names = Dictionary(participants.compactMap { p in p.id.map { ($0, p.displayName) } }, uniquingKeysWith: { first, _ in first })
        return selectedSegments(segments).map { segment in
            let id = segment.id.map(String.init) ?? "?"
            let text = segment.text
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return "[\(id)] \(timestamp(ms: segment.tStartMs)) \(speakerName(for: segment, names: names)): \(text)"
        }
    }

    /// Non-volatile, non-echo segments of the final pass if it has any, else of the live pass,
    /// ordered by start time (then id).
    public static func selectedSegments(_ segments: [Segment]) -> [Segment] {
        let usable = segments.filter { !$0.isVolatile && !$0.isEchoDuplicate }
        let pass = selectedPass(usable)
        return usable
            .filter { $0.pass == pass }
            .sorted { ($0.tStartMs, $0.id ?? 0) < ($1.tStartMs, $1.id ?? 0) }
    }

    /// `.final` when any usable final-pass segment exists, else `.live`.
    public static func selectedPass(_ segments: [Segment]) -> SegmentPass {
        segments.contains { $0.pass == .final && !$0.isVolatile && !$0.isEchoDuplicate } ? .final : .live
    }

    /// Participant display name, else `Me` (mic) / `Them` (system).
    public static func speakerName(for segment: Segment, participants: [Participant]) -> String {
        speakerName(for: segment, names: Dictionary(
            participants.compactMap { p in p.id.map { ($0, p.displayName) } }, uniquingKeysWith: { first, _ in first }))
    }

    /// `hh:mm:ss` from milliseconds since session start.
    public static func timestamp(ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private static func speakerName(for segment: Segment, names: [Int64: String]) -> String {
        if let id = segment.participantID, let name = names[id] { return name }
        return segment.channel == .mic ? "Me" : "Them"
    }
}
