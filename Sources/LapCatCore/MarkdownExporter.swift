import Foundation

/// Everything an export of one meeting needs, loaded once from the store.
public struct MeetingExport: Sendable {
    public var meeting: Meeting
    public var calendar: CalendarSnapshot?
    public var participants: [Participant]
    /// All stored segments of the meeting (both passes); exporters pick the transcript pass themselves.
    public var segments: [Segment]
    public var rawNote: String
    /// Newest enhanced note, if any.
    public var enhancedNote: EnhancedNote?

    public init(
        meeting: Meeting, calendar: CalendarSnapshot? = nil, participants: [Participant] = [],
        segments: [Segment] = [], rawNote: String = "", enhancedNote: EnhancedNote? = nil
    ) {
        self.meeting = meeting
        self.calendar = calendar
        self.participants = participants
        self.segments = segments
        self.rawNote = rawNote
        self.enhancedNote = enhancedNote
    }

    public static func load(meetingID: String, store: Store) async throws -> MeetingExport {
        guard let meeting = try await store.meeting(id: meetingID) else { throw StoreError.notFound("meeting \(meetingID)") }
        return MeetingExport(
            meeting: meeting,
            calendar: try await store.calendarSnapshot(meetingID: meetingID),
            participants: try await store.participants(meetingID: meetingID),
            segments: try await store.segments(meetingID: meetingID),
            rawNote: try await store.rawNote(meetingID: meetingID)?.markdown ?? "",
            enhancedNote: try await store.enhancedNotes(meetingID: meetingID).first)
    }
}

public enum TranscriptExportFormat: String, CaseIterable, Sendable {
    case md, txt, srt, vtt

    public var fileExtension: String { rawValue }
}

/// Markdown / plain-text / subtitle renderings of a meeting (PRD FR-10). Pure functions of a `MeetingExport`.
public enum MarkdownExporter {
    // NOTE: citation scanning and the transcript speaker/selection rules duplicate E7's `Citations` and
    // `TranscriptFormatter` (not yet on main); switch to those when they land.

    /// Newest enhanced note with every `[[s:ID]]` replaced by the cited segment's `(hh:mm:ss)`; adjacent
    /// citations share one parenthesis, unknown ids are dropped. Falls back to the raw note.
    public static func notes(_ export: MeetingExport) -> String {
        guard let note = export.enhancedNote else { return export.rawNote }
        let starts = Dictionary(export.segments.compactMap { s in s.id.map { ($0, s.tStartMs) } }, uniquingKeysWith: min)
        return replacingCitationRuns(in: note.markdown) { refs in
            var seen = Set<String>()
            let stamps = refs.compactMap { ref -> String? in
                guard ref.meetingID == nil || ref.meetingID == export.meeting.id, let ms = starts[ref.segmentID] else { return nil }
                let stamp = timestamp(ms: ms)
                return seen.insert(stamp).inserted ? stamp : nil
            }
            return stamps.isEmpty ? "" : "(" + stamps.joined(separator: ", ") + ")"
        }
    }

    /// `notes` as Slack-friendly plain text: headings become UPPERCASE lines, bullets `•`, bold and
    /// inline-code markers removed.
    public static func plainText(_ export: MeetingExport) -> String {
        notes(export).components(separatedBy: "\n").map { line -> String in
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            var body = String(line.dropFirst(indent.count))
            if let heading = body.firstMatch(of: /^#{1,6}\s+(.*)$/) {
                return String(indent) + stripInline(String(heading.1)).uppercased()
            }
            if let bullet = body.firstMatch(of: /^[-*+]\s+(.*)$/) {
                body = "• " + String(bullet.1)
            }
            return String(indent) + stripInline(body)
        }.joined(separator: "\n")
    }

    /// Full meeting document: YAML frontmatter, then enhanced notes, my notes and the transcript.
    public static func bundle(_ export: MeetingExport, timeZone: TimeZone = .current) -> String {
        let meeting = export.meeting
        let lines = transcriptLines(export)
        var speakers: [String] = []
        for line in lines where !speakers.contains(line.speaker) { speakers.append(line.speaker) }
        var out = "---\n"
        out += "title: \(yamlString(meeting.title))\n"
        out += "date: \(isoDate(meeting.startedAt, timeZone: timeZone))\n"
        out += "attendees: \(yamlList(attendees(export)))\n"
        out += "speakers: \(yamlList(speakers))\n"
        out += "source_app: \(yamlString(meeting.sourceApp))\n"
        out += "duration: \(timestamp(ms: durationMs(export, lines: lines)))\n"
        out += "---\n\n"
        out += "# \(meeting.title)\n\n"
        out += "## Enhanced notes\n\n"
        out += export.enhancedNote.map { _ in notes(export) } ?? "_No enhanced notes._"
        out += "\n\n## My notes\n\n"
        let raw = export.rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
        out += raw.isEmpty ? "_No notes._" : raw
        out += "\n\n## Transcript\n\n"
        let transcript = markdownTranscript(lines)
        out += transcript.isEmpty ? "_No transcript._" : transcript
        out += "\n"
        return out
    }

    /// The transcript alone. `md`/`txt` group consecutive lines of one speaker (gaps ≤ 8 s) into
    /// paragraphs; `srt`/`vtt` emit one cue per segment.
    public static func transcript(_ export: MeetingExport, format: TranscriptExportFormat) -> String {
        let lines = transcriptLines(export)
        switch format {
        case .md:
            return markdownTranscript(lines) + "\n"
        case .txt:
            return paragraphs(lines).map { "[\(timestamp(ms: $0.startMs))] \($0.speaker): \($0.text)" }
                .joined(separator: "\n\n") + "\n"
        case .srt:
            return lines.enumerated().map { index, line in
                "\(index + 1)\n\(cueTime(line.startMs, separator: ",")) --> \(cueTime(line.endMs, separator: ","))\n\(line.speaker): \(line.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            let cues = lines.map { line in
                "\(cueTime(line.startMs, separator: ".")) --> \(cueTime(line.endMs, separator: "."))\n\(line.speaker): \(line.text)\n"
            }
            return (["WEBVTT\n"] + cues).joined(separator: "\n")
        }
    }

    /// `YYYY-MM-DD <Title>.<ext>` with every character outside `[A-Za-z0-9 _-]` in the title replaced by `-`.
    public static func fileName(for meeting: Meeting, fileExtension: String = "md", timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: meeting.startedAt)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        var title = String(meeting.title.unicodeScalars.map { scalar -> Character in
            let allowed = scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || " _-".unicodeScalars.contains(scalar))
            return allowed ? Character(scalar) : "-"
        }).trimmingCharacters(in: .whitespaces)
        if title.count > 120 { title = String(title.prefix(120)).trimmingCharacters(in: .whitespaces) }
        if title.isEmpty { title = "Untitled" }
        return "\(date) \(title).\(fileExtension)"
    }

    /// `hh:mm:ss` for a millisecond offset.
    public static func timestamp(ms: Int) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    // MARK: - Transcript lines

    struct Line: Equatable {
        var segmentID: Int64?
        var startMs: Int
        var endMs: Int
        var speaker: String
        var participantID: Int64?
        var channel: Channel
        var text: String
    }

    /// Non-volatile, non-echo segments of the final pass if any exist (else live), by start time.
    static func transcriptLines(_ export: MeetingExport) -> [Line] {
        let usable = export.segments.filter { !$0.isVolatile && !$0.isEchoDuplicate }
        let pass: SegmentPass = usable.contains { $0.pass == .final } ? .final : .live
        let names = Dictionary(export.participants.compactMap { p in p.id.map { ($0, p.displayName) } }, uniquingKeysWith: { a, _ in a })
        return usable.filter { $0.pass == pass }
            .sorted { ($0.tStartMs, $0.id ?? 0) < ($1.tStartMs, $1.id ?? 0) }
            .map { segment in
                let speaker = segment.participantID.flatMap { names[$0] } ?? (segment.channel == .mic ? "Me" : "Them")
                return Line(
                    segmentID: segment.id, startMs: segment.tStartMs, endMs: max(segment.tEndMs, segment.tStartMs),
                    speaker: speaker, participantID: segment.participantID, channel: segment.channel,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    static let paragraphGapMs = 8_000

    static func paragraphs(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        for line in lines {
            if var last = result.last, last.speaker == line.speaker, last.channel == line.channel,
               last.participantID == line.participantID, line.startMs - last.endMs <= paragraphGapMs
            {
                last.text += " " + line.text
                last.endMs = max(last.endMs, line.endMs)
                result[result.count - 1] = last
            } else {
                result.append(line)
            }
        }
        return result
    }

    private static func markdownTranscript(_ lines: [Line]) -> String {
        paragraphs(lines).map { "**\($0.speaker)** (\(timestamp(ms: $0.startMs))): \($0.text)" }.joined(separator: "\n\n")
    }

    /// `HH:MM:SS<sep>mmm` (SRT uses `,`, WebVTT `.`).
    static func cueTime(_ ms: Int, separator: String) -> String {
        let ms = max(0, ms)
        let seconds = ms / 1000
        return String(format: "%02d:%02d:%02d%@%03d", seconds / 3600, seconds % 3600 / 60, seconds % 60, separator, ms % 1000)
    }

    // MARK: - Frontmatter

    private static func attendees(_ export: MeetingExport) -> [String] {
        if let calendar = export.calendar, !calendar.attendees.isEmpty { return calendar.attendees }
        let named: Set<ParticipantSource> = [.calendar, .zoomAX, .meetAX, .manual]
        return export.participants.filter { named.contains($0.source) }.map(\.displayName)
    }

    private static func durationMs(_ export: MeetingExport, lines: [Line]) -> Int {
        if let ended = export.meeting.endedAt {
            return Int((ended.timeIntervalSince(export.meeting.startedAt) * 1000).rounded())
        }
        return lines.map(\.endMs).max() ?? 0
    }

    private static func isoDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// A YAML double-quoted scalar (JSON string syntax is valid YAML).
    private static func yamlString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    private static func yamlList(_ values: [String]) -> String {
        "[" + values.map(yamlString).joined(separator: ", ") + "]"
    }

    // MARK: - Inline Markdown

    private static func stripInline(_ text: String) -> String {
        text.replacing(/\*\*(.+?)\*\*/) { String($0.1) }
            .replacing(/__(.+?)__/) { String($0.1) }
            .replacing(/`([^`]*)`/) { String($0.1) }
    }

    // MARK: - Citations

    struct CitationRef: Equatable {
        var meetingID: String?
        var segmentID: Int64
    }

    /// Replaces each run of adjacent citations (`[[s:1]][[s:2]]`, optionally separated by spaces or
    /// commas) with `transform(refs)`. A space before a run whose replacement is empty is removed too.
    static func replacingCitationRuns(in text: String, _ transform: ([CitationRef]) -> String) -> String {
        let citation = /\[\[(?:m:([^#\]\s]+)#)?s:(\d+)\]\]/
        let run = /( ?)((?:\[\[(?:m:[^#\]\s]+#)?s:\d+\]\][ ,]*)*\[\[(?:m:[^#\]\s]+#)?s:\d+\]\])/
        return text.replacing(run) { match in
            let refs = String(match.2).matches(of: citation).compactMap { m -> CitationRef? in
                guard let id = Int64(m.2) else { return nil }
                return CitationRef(meetingID: m.1.map(String.init), segmentID: id)
            }
            let replacement = transform(refs)
            return replacement.isEmpty ? "" : String(match.1) + replacement
        }
    }
}
