import Foundation
import Testing

@testable import LapCatCore

struct MarkdownExporterTests {
    private func fixture() -> MeetingExport {
        let start = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC
        let meeting = Meeting(
            id: "M1", title: "Pricing: Q4 / review?", startedAt: start, endedAt: start.addingTimeInterval(3_725),
            sourceApp: "zoom", startedBy: .manual, createdAt: start, updatedAt: start)
        let participants = [
            Participant(id: 1, meetingID: "M1", displayName: "Me Myself", source: .manual, isMe: true),
            Participant(id: 2, meetingID: "M1", displayName: "Priya Shah", source: .zoomAX),
            Participant(id: 3, meetingID: "M1", displayName: "Speaker 2", source: .cluster),
        ]
        let segments = [
            Segment(
                id: 10, meetingID: "M1", channel: .system, tStartMs: 1_000, tEndMs: 4_500, text: "Hello there.",
                participantID: 2, pass: .final),
            Segment(
                id: 11, meetingID: "M1", channel: .system, tStartMs: 5_000, tEndMs: 7_250, text: "Pricing is up.",
                participantID: 2, pass: .final),
            Segment(
                id: 12, meetingID: "M1", channel: .mic, tStartMs: 3_723_004, tEndMs: 3_725_000, text: "Agreed.",
                participantID: 1, pass: .final),
            Segment(
                id: 13, meetingID: "M1", channel: .mic, tStartMs: 5_100, tEndMs: 7_000, text: "Pricing is up.",
                pass: .final, isEchoDuplicate: true),
            Segment(
                id: 14, meetingID: "M1", channel: .system, tStartMs: 1_000, tEndMs: 2_000, text: "live text",
                pass: .live),
        ]
        let enhanced = EnhancedNote(
            id: 1, meetingID: "M1", version: 1, templateID: "general", provider: "claude-cli", model: "sonnet",
            markdown:
                "## Decisions\n- **Raise** prices [[s:11]]\n- Kickoff [[s:10]][[s:11]] done\n- Gone [[s:999]]\n- Ended [[m:M1#s:12]]",
            basedOnPass: .final, createdAt: start)
        return MeetingExport(
            meeting: meeting,
            calendar: CalendarSnapshot(meetingID: "M1", attendees: ["Priya Shah", "Me Myself"]),
            participants: participants, segments: segments, rawNote: "- raise prices", enhancedNote: enhanced)
    }

    @Test func srtCuesUseCommaMillisecondsAndSequentialIndexes() {
        let srt = MarkdownExporter.transcript(fixture(), format: .srt)
        #expect(
            srt == """
                1
                00:00:01,000 --> 00:00:04,500
                Priya Shah: Hello there.

                2
                00:00:05,000 --> 00:00:07,250
                Priya Shah: Pricing is up.

                3
                01:02:03,004 --> 01:02:05,000
                Me Myself: Agreed.

                """)
    }

    @Test func vttHasHeaderAndDotMilliseconds() {
        let vtt = MarkdownExporter.transcript(fixture(), format: .vtt)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:04.500\nPriya Shah: Hello there.\n"))
        #expect(vtt.contains("01:02:03.004 --> 01:02:05.000\nMe Myself: Agreed."))
        #expect(!vtt.contains(","))
    }

    @Test func notesReplaceCitationsWithTimestampsAndDropUnknownIDs() {
        let notes = MarkdownExporter.notes(fixture())
        #expect(
            notes
                == "## Decisions\n- **Raise** prices (00:00:05)\n- Kickoff (00:00:01, 00:00:05) done\n- Gone\n- Ended (01:02:03)"
        )
    }

    @Test func plainTextUppercasesHeadingsAndUsesBullets() {
        let text = MarkdownExporter.plainText(fixture())
        #expect(text.hasPrefix("DECISIONS\n• Raise prices (00:00:05)\n"))
    }

    @Test func bundleHasFrontmatterAndThreeSections() {
        let doc = MarkdownExporter.bundle(fixture(), timeZone: utc)
        #expect(
            doc.hasPrefix(
                """
                ---
                title: "Pricing: Q4 / review?"
                date: 2026-09-21T14:13:20Z
                attendees: ["Priya Shah", "Me Myself"]
                speakers: ["Priya Shah", "Me Myself"]
                source_app: "zoom"
                duration: 01:02:05
                ---

                """))
        let enhanced = try! #require(doc.range(of: "## Enhanced notes"))
        let mine = try! #require(doc.range(of: "## My notes\n\n- raise prices"))
        let transcript = try! #require(doc.range(of: "## Transcript"))
        #expect(enhanced.lowerBound < mine.lowerBound && mine.lowerBound < transcript.lowerBound)
        // Same-speaker lines within 8 s merge into one paragraph; echo duplicates and live rows are excluded.
        #expect(
            doc.contains("**Priya Shah** (00:00:01): Hello there. Pricing is up.\n\n**Me Myself** (01:02:03): Agreed."))
        #expect(!doc.contains("live text"))
    }

    @Test func fileNameSanitisesTitle() {
        var meeting = fixture().meeting
        #expect(MarkdownExporter.fileName(for: meeting, timeZone: utc) == "2026-09-21 Pricing- Q4 - review-.md")
        meeting.title = "Café 1:1 — Ana"
        #expect(
            MarkdownExporter.fileName(for: meeting, fileExtension: "srt", timeZone: utc)
                == "2026-09-21 Caf- 1-1 - Ana.srt")
        meeting.title = "  "
        #expect(MarkdownExporter.fileName(for: meeting, timeZone: utc) == "2026-09-21 Untitled.md")
    }
}
