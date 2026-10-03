import Foundation

/// Prompt strings for enhancement, classification and titling. Citations use `[[s:ID]]`, where ID is
/// the `[<id>]` prefix of a `TranscriptFormatter.forLLM` line.
public enum Prompts {
    public static let enhanceSystem = """
        You are LapCat, a meeting-notes writer. You receive the user's raw notes (verbatim, possibly sparse shorthand), a speaker-labeled transcript with numbered segments, calendar metadata, and a template. Produce Markdown notes that follow the template's sections and instructions.
        Rules:
        1. Preserve every non-empty line of the user's raw notes verbatim, placed under the most relevant section, and expand around them.
        2. Every bullet or sentence you add that states a fact, decision, action item, question, or quote MUST end with one or more citations of the form [[s:ID]] where ID is a transcript segment number that supports it. Do not add citations to headings or to the user's own lines.
        3. Never invent facts absent from the notes and transcript. Omit template sections with no supporting content.
        4. Use speaker names exactly as given; "Me" is the user. Write in the user's voice: first person for the user's own commitments.
        5. Output only the Markdown. No preamble, no code fences.
        """

    /// Map step of map-reduce enhancement: one call per 10-minute transcript window.
    public static let chunkSummarySystem = """
        Summarize this portion of a meeting transcript as dense Markdown bullets. Keep speaker names, decisions, action items with owners, numbers, and quotes. Every bullet MUST end with [[s:ID]] citations to the segment numbers it comes from. Output only the bullets.
        """

    public static let titleSystem = """
        Write a concise meeting title (max 8 words, no quotes). Reply with only {"title": "…"}.
        """

    /// Meeting metadata shared by the enhance, reduce, classify and title prompts.
    public struct MeetingContext: Sendable, Equatable {
        public var title: String
        public var date: Date
        public var attendees: [String]

        public init(title: String, date: Date, attendees: [String]) {
            self.title = title
            self.date = date
            self.attendees = attendees
        }
    }

    public static func enhanceUser(
        meeting: MeetingContext, templateName: String, templateBody: String, rawNotes: String, transcript: String
    ) -> String {
        notesPrompt(meeting: meeting, templateName: templateName, templateBody: templateBody, rawNotes: rawNotes)
            + "\n\n# Transcript\n\(transcript)"
    }

    /// `enhanceUser` with the transcript replaced by per-window summaries (which carry their citations).
    public static func reduceUser(
        meeting: MeetingContext, templateName: String, templateBody: String, rawNotes: String, summaries: String
    ) -> String {
        notesPrompt(meeting: meeting, templateName: templateName, templateBody: templateBody, rawNotes: rawNotes)
            + "\n\n# Transcript summaries (by 10-minute window, with segment citations)\n\(summaries)"
    }

    public static func classifySystem(templateIDs: [String]) -> String {
        "Choose the best note template for this meeting. Reply with only a JSON object {\"template_id\": \"<id>\"} where id is one of: \(templateIDs.joined(separator: ", "))."
    }

    /// Title, attendees and the first five minutes of transcript.
    public static func classifyUser(meeting: MeetingContext, openingTranscript: String) -> String {
        "Title: \(meeting.title)\nAttendees: \(attendees(meeting.attendees))\n\n# Transcript (first 5 minutes)\n\(transcriptOrNone(openingTranscript))"
    }

    /// First five minutes of transcript and attendees.
    public static func titleUser(attendees names: [String], openingTranscript: String) -> String {
        "Attendees: \(attendees(names))\n\n# Transcript (first 5 minutes)\n\(transcriptOrNone(openingTranscript))"
    }

    /// `Wednesday, October 1, 2026 14:05` in the local time zone.
    public static func formatDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy HH:mm"
        return formatter.string(from: date)
    }

    private static func notesPrompt(
        meeting: MeetingContext, templateName: String, templateBody: String, rawNotes: String
    ) -> String {
        let notes = rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(none)" : rawNotes
        return """
            # Meeting
            Title: \(meeting.title)
            Date: \(formatDate(meeting.date))
            Attendees: \(attendees(meeting.attendees))

            # Template: \(templateName)
            \(templateBody)

            # My raw notes
            \(notes)
            """
    }

    private static func attendees(_ names: [String]) -> String {
        names.isEmpty ? "(unknown)" : names.joined(separator: ", ")
    }

    private static func transcriptOrNone(_ transcript: String) -> String {
        transcript.isEmpty ? "(no transcript yet)" : transcript
    }
}
