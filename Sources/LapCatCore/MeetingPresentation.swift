import Foundation

// Pure logic behind the meeting views (sidebar, transcript, notes editor, enhanced notes),
// factored out of SwiftUI so it can be tested.

// MARK: - Sidebar sections

public enum MeetingListSection: String, Sendable, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This week"
    case earlier = "Earlier"

    /// Groups meetings (kept in their given order) by `startedAt` relative to `now`; empty sections
    /// are omitted. "This week" = the calendar week containing `now`, before yesterday.
    public static func group(_ meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [(MeetingListSection, [Meeting])] {
        var buckets: [MeetingListSection: [Meeting]] = [:]
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        for meeting in meetings {
            let date = meeting.startedAt
            let section: MeetingListSection
            if calendar.isDate(date, inSameDayAs: now) {
                section = .today
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
                section = .yesterday
            } else if let week, week.contains(date), date < now {
                section = .thisWeek
            } else {
                section = .earlier
            }
            buckets[section, default: []].append(meeting)
        }
        return allCases.compactMap { section in buckets[section].map { (section, $0) } }
    }
}

// MARK: - Transcript paragraphs

/// Consecutive segments of one speaker shown as one bubble / paragraph.
public struct TranscriptParagraph: Sendable, Hashable, Identifiable {
    public var segments: [Segment]
    public var channel: Channel
    public var participantID: Int64?
    /// The volatile (in-progress hypothesis) segment of a channel; never merged with finalized text.
    public var isVolatile: Bool

    /// The first segment's id.
    public var id: Int64 { segments.first?.id ?? 0 }
    public var tStartMs: Int { segments.first?.tStartMs ?? 0 }
    public var tEndMs: Int { segments.last?.tEndMs ?? 0 }
    public var text: String { segments.map(\.text).joined(separator: " ") }

    public func contains(segmentID: Int64) -> Bool { segments.contains { $0.id == segmentID } }
}

public enum TranscriptGrouping {
    /// Gap (previous end → next start) up to which consecutive same-speaker segments share a paragraph.
    public static let maxGapMs = 8_000

    /// Segments to display: the final pass if it has any non-volatile rows, else the live pass
    /// (volatile rows included); echo duplicates only when `showEcho`.
    public static func displayed(_ segments: [Segment], showEcho: Bool) -> [Segment] {
        let pass = TranscriptFormatter.selectedPass(segments)
        return segments
            .filter { $0.pass == pass && (showEcho || !$0.isEchoDuplicate) }
            .sorted { ($0.tStartMs, $0.id ?? 0) < ($1.tStartMs, $1.id ?? 0) }
    }

    /// Groups `displayed(segments, showEcho:)` into paragraphs by `(channel, participant)` with gaps
    /// ≤ `maxGapMs`. Volatile segments become their own paragraphs, after all finalized ones.
    public static func paragraphs(_ segments: [Segment], showEcho: Bool) -> [TranscriptParagraph] {
        let shown = displayed(segments, showEcho: showEcho)
        var result: [TranscriptParagraph] = []
        for segment in shown where !segment.isVolatile {
            if var last = result.last,
               last.channel == segment.channel, last.participantID == segment.participantID,
               segment.tStartMs - last.tEndMs <= maxGapMs
            {
                last.segments.append(segment)
                result[result.count - 1] = last
            } else {
                result.append(TranscriptParagraph(
                    segments: [segment], channel: segment.channel, participantID: segment.participantID, isVolatile: false))
            }
        }
        for segment in shown where segment.isVolatile {
            result.append(TranscriptParagraph(
                segments: [segment], channel: segment.channel, participantID: segment.participantID, isVolatile: true))
        }
        return result
    }

    /// Speaker-labelled plain text: `Speaker (hh:mm:ss): text` paragraphs separated by blank lines.
    public static func plainText(_ paragraphs: [TranscriptParagraph], participants: [Participant]) -> String {
        paragraphs.compactMap { paragraph in
            guard let first = paragraph.segments.first else { return nil }
            let speaker = TranscriptFormatter.speakerName(for: first, participants: participants)
            return "\(speaker) (\(TranscriptFormatter.timestamp(ms: paragraph.tStartMs))): \(paragraph.text)"
        }.joined(separator: "\n\n")
    }
}

// MARK: - Find in transcript

public struct TranscriptFindMatch: Sendable, Hashable {
    public var segmentID: Int64
    /// Character offsets into the segment text.
    public var range: Range<Int>
}

public enum TranscriptFind {
    /// Every case- and diacritic-insensitive occurrence of `query` in segment order; empty for a blank query.
    public static func matches(_ query: String, in segments: [Segment]) -> [TranscriptFindMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return segments.flatMap { segment -> [TranscriptFindMatch] in
            guard let id = segment.id else { return [] }
            return ranges(of: needle, in: segment.text).map { TranscriptFindMatch(segmentID: id, range: $0) }
        }
    }

    /// Non-overlapping occurrences as character offsets.
    public static func ranges(of needle: String, in text: String) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex)
        {
            let lower = text.distance(from: text.startIndex, to: found.lowerBound)
            result.append(lower..<(lower + text.distance(from: found.lowerBound, to: found.upperBound)))
            searchStart = found.upperBound
        }
        return result
    }

    /// Index after `current` (wrapping); `backwards` steps the other way. Nil when there are no matches.
    public static func step(from current: Int?, count: Int, backwards: Bool = false) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return backwards ? count - 1 : 0 }
        return ((current + (backwards ? -1 : 1)) % count + count) % count
    }
}

// MARK: - Jump to time

public enum TranscriptTime {
    /// Milliseconds for `ss`, `mm:ss` or `hh:mm:ss` (components after the first must be < 60); nil otherwise.
    public static func parse(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            if index > 0, value >= 60 { return nil }
            seconds = seconds * 60 + value
        }
        return seconds * 1000
    }

    /// The segment starting at or most recently before `ms` (the first one when `ms` precedes all).
    public static func segment(at ms: Int, in segments: [Segment]) -> Segment? {
        segments.last { $0.tStartMs <= ms } ?? segments.first
    }
}

// MARK: - Notes editor

public enum MarkdownListContinuation {
    public enum Action: Equatable, Sendable {
        /// Insert a newline followed by this prefix.
        case continueList(String)
        /// The line was only a list marker: clear it instead of adding a new item.
        case endList
    }

    /// What pressing Enter at the end of `line` does: continue a `- ` or `- [ ] ` list (keeping the
    /// indentation; a checked `- [x] ` continues unchecked), end the list on an empty item, or nil.
    public static func action(forLine line: String) -> Action? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(indent.count)
        for (marker, next) in [("- [ ] ", "- [ ] "), ("- [x] ", "- [ ] "), ("- [X] ", "- [ ] "), ("- ", "- ")] where body.hasPrefix(marker) {
            let rest = body.dropFirst(marker.count)
            return rest.trimmingCharacters(in: .whitespaces).isEmpty ? .endList : .continueList(indent + next)
        }
        return nil
    }
}

public enum MarkdownBold {
    /// `text` with `range` (UTF-16 offsets) wrapped in `**`, and the range of the wrapped content.
    /// An already-wrapped selection is unwrapped.
    public static func toggle(_ text: String, range: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let selected = ns.substring(with: range)
        if selected.count >= 4, selected.hasPrefix("**"), selected.hasSuffix("**") {
            let inner = String(selected.dropFirst(2).dropLast(2))
            return (ns.replacingCharacters(in: range, with: inner), NSRange(location: range.location, length: (inner as NSString).length))
        }
        if range.location >= 2, range.location + range.length + 2 <= ns.length,
           ns.substring(with: NSRange(location: range.location - 2, length: 2)) == "**",
           ns.substring(with: NSRange(location: range.location + range.length, length: 2)) == "**"
        {
            let outer = NSRange(location: range.location - 2, length: range.length + 4)
            return (ns.replacingCharacters(in: outer, with: selected), NSRange(location: range.location - 2, length: range.length))
        }
        return (ns.replacingCharacters(in: range, with: "**\(selected)**"), NSRange(location: range.location + 2, length: range.length))
    }
}

/// One line of enhanced-note Markdown, classified for line-by-line rendering (Text renders inline
/// Markdown only, so headings and list markers are interpreted here).
public struct MarkdownLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case blank
        case heading(level: Int)
        /// `checked` is nil for a plain bullet, else the checkbox state.
        case bullet(depth: Int, checked: Bool?)
        case numbered(depth: Int, marker: String)
        case text
    }

    public var kind: Kind
    /// The inline Markdown after the block marker.
    public var content: String

    public static func parse(_ line: String) -> MarkdownLine {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let body = line.dropFirst(indent.count)
        if body.trimmingCharacters(in: .whitespaces).isEmpty { return MarkdownLine(kind: .blank, content: "") }
        if let match = body.wholeMatch(of: /(#{1,6})\s+(.*)/) {
            return MarkdownLine(kind: .heading(level: match.1.count), content: String(match.2))
        }
        if let match = body.wholeMatch(of: /[-*+]\s+\[([ xX])\]\s+(.*)/) {
            return MarkdownLine(kind: .bullet(depth: depth, checked: match.1 != " "), content: String(match.2))
        }
        if let match = body.wholeMatch(of: /[-*+]\s+(.*)/) {
            return MarkdownLine(kind: .bullet(depth: depth, checked: nil), content: String(match.1))
        }
        if let match = body.wholeMatch(of: /(\d+[.)])\s+(.*)/) {
            return MarkdownLine(kind: .numbered(depth: depth, marker: String(match.1)), content: String(match.2))
        }
        return MarkdownLine(kind: .text, content: String(body))
    }
}

// MARK: - Providers and enhanced-note versions

public enum ProviderLabel {
    /// "Claude via CLI" / "Claude API" / "Local" for a provider id, or for `<provider>:<model>`
    /// as stored in `meeting.llm_provider_used`. Unknown ids are returned as written.
    public static func displayName(_ providerOrUsed: String) -> String {
        let id = providerOrUsed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? providerOrUsed
        switch id {
        case "claude-cli": return "Claude via CLI"
        case "anthropic-api": return "Claude API"
        case "local": return "Local"
        default: return providerOrUsed
        }
    }
}

public enum EnhancedNoteLabel {
    /// `v3 · One-on-one · Claude via CLI · 12:04` (time of day in `timeZone`).
    public static func label(for note: EnhancedNote, templateName: String?, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return ["v\(note.version)", templateName ?? note.templateID, ProviderLabel.displayName(note.provider), formatter.string(from: note.createdAt)]
            .joined(separator: " · ")
    }
}

// MARK: - Citation links

/// What clicking a `lapcat://` citation link in a meeting does.
public enum CitationLinkAction: Equatable, Sendable {
    /// Show this meeting's transcript at the segment.
    case transcriptSegment(Int64)
    /// Open another meeting's transcript at the segment.
    case otherMeeting(meetingID: String, segmentID: Int64)
}

extension CitationLinkAction {
    /// nil for URLs that are not LapCat citations (they open normally).
    public init?(url: URL, currentMeetingID: String) {
        switch Citations.target(of: url) {
        case .segment(let id):
            self = .transcriptSegment(id)
        case .meetingSegment(let ref):
            self = ref.meetingID == currentMeetingID
                ? .transcriptSegment(ref.segmentID)
                : .otherMeeting(meetingID: ref.meetingID, segmentID: ref.segmentID)
        case nil:
            return nil
        }
    }
}

// MARK: - Speaker suggestions

/// An LLM (or platform) suggestion that the diarized cluster `cluster` (a `Speaker N` participant) is `suggested`.
public struct SpeakerSuggestion: Sendable, Hashable, Identifiable {
    public var suggested: Participant
    public var cluster: Participant
    public var id: Int64 { suggested.id ?? 0 }
    public var clusterLabel: String { cluster.clusterLabel ?? cluster.displayName }

    /// Suggestions pending confirmation: a participant whose `clusterLabel` names a cluster, whose
    /// source is not `.cluster`, and that has no segments, paired with the `.cluster` participant of that label.
    public static func pending(participants: [Participant], segments: [Segment]) -> [SpeakerSuggestion] {
        let assigned = Set(segments.compactMap(\.participantID))
        let clusters = Dictionary(
            participants.compactMap { p in p.source == .cluster ? p.clusterLabel.map { ($0, p) } : nil },
            uniquingKeysWith: { first, _ in first })
        return participants.compactMap { p in
            guard p.source != .cluster, let label = p.clusterLabel, let id = p.id, !assigned.contains(id),
                  let cluster = clusters[label] else { return nil }
            return SpeakerSuggestion(suggested: p, cluster: cluster)
        }
    }
}
