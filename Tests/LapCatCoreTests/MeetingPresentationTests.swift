import Foundation
import Testing

@testable import LapCatCore

struct MeetingPresentationTests {
    private func seg(
        _ id: Int64, _ channel: Channel, _ start: Int, _ end: Int, _ text: String = "x",
        participant: Int64? = nil, pass: SegmentPass = .final, volatile: Bool = false, echo: Bool = false
    ) -> Segment {
        Segment(
            id: id, meetingID: "m", channel: channel, tStartMs: start, tEndMs: end, text: text,
            participantID: participant, pass: pass, isVolatile: volatile, isEchoDuplicate: echo)
    }

    private func meeting(_ date: Date) -> Meeting {
        Meeting(title: "t", startedAt: date, startedBy: .manual, createdAt: date, updatedAt: date)
    }

    // MARK: Sections

    @Test func meetingsGroupIntoRelativeSections() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.firstWeekday = 2  // Monday
        let now = Date(timeIntervalSince1970: 1_790_856_000)  // Thu 2026-10-01 12:00 UTC
        let day: TimeInterval = 86_400
        let meetings = [
            meeting(now.addingTimeInterval(-3_600)),  // today
            meeting(now.addingTimeInterval(-day)),  // yesterday (Wed)
            meeting(now.addingTimeInterval(-2 * day)),  // Tue, same week
            meeting(now.addingTimeInterval(-4 * day)),  // Sun, previous week
        ]
        let sections = MeetingListSection.group(meetings, now: now, calendar: calendar)
        #expect(sections.map(\.0) == [.today, .yesterday, .thisWeek, .earlier])
        #expect(sections.map(\.1.count) == [1, 1, 1, 1])
    }

    // MARK: Paragraphs

    @Test func consecutiveSameSpeakerSegmentsWithinGapShareAParagraph() {
        let paragraphs = TranscriptGrouping.paragraphs(
            [
                seg(1, .system, 0, 1_000, "a"),
                seg(2, .system, 9_000, 10_000, "b"),  // gap 8 s → same paragraph
                seg(3, .system, 18_001, 19_000, "c"),  // gap 8.001 s → new
                seg(4, .mic, 19_500, 20_000, "d"),  // other channel → new
                seg(5, .mic, 20_500, 21_000, "e", participant: 7),  // other participant → new
            ], showEcho: false)
        #expect(paragraphs.map { $0.segments.compactMap(\.id) } == [[1, 2], [3], [4], [5]])
        #expect(paragraphs[0].text == "a b")
    }

    @Test func finalPassWinsAndVolatileRowsComeLastAndEchoIsHiddenByDefault() {
        let live = [
            seg(1, .system, 0, 1_000, pass: .live),
            seg(2, .mic, 500, 900, pass: .live, volatile: true),
            seg(3, .system, 1_100, 1_500, pass: .live),
            seg(4, .mic, 2_000, 2_500, pass: .live, echo: true),
        ]
        let liveParagraphs = TranscriptGrouping.paragraphs(live, showEcho: false)
        #expect(liveParagraphs.map { $0.segments.compactMap(\.id) } == [[1, 3], [2]])
        #expect(liveParagraphs.last?.isVolatile == true)
        #expect(
            TranscriptGrouping.paragraphs(live, showEcho: true).flatMap { $0.segments.compactMap(\.id) }.contains(4))

        let withFinal = live + [seg(9, .system, 0, 1_000, pass: .final)]
        #expect(
            TranscriptGrouping.paragraphs(withFinal, showEcho: false).flatMap { $0.segments.compactMap(\.id) } == [9])
    }

    @Test func plainTextIsSpeakerLabelled() {
        let me = Participant(id: 7, meetingID: "m", displayName: "Mason", source: .manual, isMe: true)
        let paragraphs = TranscriptGrouping.paragraphs(
            [
                seg(1, .system, 61_000, 62_000, "hello"),
                seg(2, .mic, 63_000, 64_000, "hi", participant: 7),
            ], showEcho: false)
        #expect(
            TranscriptGrouping.plainText(paragraphs, participants: [me])
                == "Them (00:01:01): hello\n\nMason (00:01:03): hi")
    }

    // MARK: Find

    @Test func findIsCaseInsensitiveAndCyclesWithWrap() {
        let matches = TranscriptFind.matches(
            "price",
            in: [seg(1, .system, 0, 1, "Price and PRICE"), seg(2, .mic, 2, 3, "no"), seg(3, .mic, 4, 5, "prices")])
        #expect(
            matches == [
                TranscriptFindMatch(segmentID: 1, range: 0..<5),
                TranscriptFindMatch(segmentID: 1, range: 10..<15),
                TranscriptFindMatch(segmentID: 3, range: 0..<5),
            ])
        #expect(TranscriptFind.matches("  ", in: [seg(1, .mic, 0, 1, "  ")]).isEmpty)
        #expect(TranscriptFind.step(from: nil, count: 3) == 0)
        #expect(TranscriptFind.step(from: 2, count: 3) == 0)
        #expect(TranscriptFind.step(from: 0, count: 3, backwards: true) == 2)
        #expect(TranscriptFind.step(from: nil, count: 0) == nil)
    }

    // MARK: Jump to time

    @Test func timeParsingAcceptsSecondsMinutesAndHours() {
        #expect(TranscriptTime.parse("75") == 75_000)
        #expect(TranscriptTime.parse("1:05") == 65_000)
        #expect(TranscriptTime.parse("01:02:03") == 3_723_000)
        #expect(TranscriptTime.parse("1:75") == nil)
        #expect(TranscriptTime.parse("1::2") == nil)
        #expect(TranscriptTime.parse("abc") == nil)
        #expect(TranscriptTime.parse("1:2:3:4") == nil)
        let segments = [seg(1, .mic, 1_000, 2_000), seg(2, .mic, 5_000, 6_000)]
        #expect(TranscriptTime.segment(at: 4_000, in: segments)?.id == 1)
        #expect(TranscriptTime.segment(at: 500, in: segments)?.id == 1)
        #expect(TranscriptTime.segment(at: 9_000, in: segments)?.id == 2)
    }

    // MARK: Notes editor

    @Test func listContinuation() {
        #expect(MarkdownListContinuation.action(forLine: "- item") == .continueList("- "))
        #expect(MarkdownListContinuation.action(forLine: "  - [ ] todo") == .continueList("  - [ ] "))
        #expect(MarkdownListContinuation.action(forLine: "- [x] done") == .continueList("- [ ] "))
        #expect(MarkdownListContinuation.action(forLine: "- ") == .endList)
        #expect(MarkdownListContinuation.action(forLine: "- [ ] ") == .endList)
        #expect(MarkdownListContinuation.action(forLine: "plain") == nil)
        #expect(MarkdownListContinuation.action(forLine: "-dash") == nil)
    }

    @Test func boldToggleWrapsAndUnwraps() {
        let wrapped = MarkdownBold.toggle("say hi now", range: NSRange(location: 4, length: 2))
        #expect(wrapped.text == "say **hi** now")
        #expect(wrapped.selection == NSRange(location: 6, length: 2))
        let unwrapped = MarkdownBold.toggle(wrapped.text, range: wrapped.selection)
        #expect(unwrapped.text == "say hi now")
        #expect(unwrapped.selection == NSRange(location: 4, length: 2))
        #expect(MarkdownBold.toggle("x", range: NSRange(location: 1, length: 0)).text == "x****")
    }

    @Test func markdownLinesAreClassified() {
        #expect(MarkdownLine.parse("## Decisions") == MarkdownLine(kind: .heading(level: 2), content: "Decisions"))
        #expect(
            MarkdownLine.parse("  - [x] ship [[s:4]]")
                == MarkdownLine(kind: .bullet(depth: 1, checked: true), content: "ship [[s:4]]"))
        #expect(MarkdownLine.parse("* point") == MarkdownLine(kind: .bullet(depth: 0, checked: nil), content: "point"))
        #expect(
            MarkdownLine.parse("2. second") == MarkdownLine(kind: .numbered(depth: 0, marker: "2."), content: "second"))
        #expect(MarkdownLine.parse("   ") == MarkdownLine(kind: .blank, content: ""))
        #expect(MarkdownLine.parse("#hashtag") == MarkdownLine(kind: .text, content: "#hashtag"))
    }

    // MARK: Labels and links

    @Test func versionLabelAndProviderNames() {
        let note = EnhancedNote(
            meetingID: "m", version: 3, templateID: "one-on-one", provider: "claude-cli", model: "sonnet",
            markdown: "", basedOnPass: .final, createdAt: Date(timeIntervalSince1970: 1_790_856_240))  // 12:04 UTC
        #expect(
            EnhancedNoteLabel.label(for: note, templateName: "One-on-one", timeZone: utc)
                == "v3 · One-on-one · Claude via CLI · 12:04")
        #expect(ProviderLabel.displayName("anthropic-api:claude-haiku-4-5") == "Claude API")
        #expect(ProviderLabel.displayName("local") == "Local")
        #expect(ProviderLabel.displayName("ollama:x") == "ollama:x")
    }

    @Test func citationLinksResolveToTranscriptOrOtherMeeting() throws {
        let linked = Citations.linkified("Ship it [[s:42]] and [[m:B#s:7]]")
        let urls = try #require(linked.matches(of: /\((lapcat:[^)]+)\)/).map { URL(string: String($0.1))! } as [URL]?)
        #expect(CitationLinkAction(url: urls[0], currentMeetingID: "A") == .transcriptSegment(42))
        #expect(CitationLinkAction(url: urls[1], currentMeetingID: "A") == .otherMeeting(meetingID: "B", segmentID: 7))
        #expect(CitationLinkAction(url: urls[1], currentMeetingID: "B") == .transcriptSegment(7))
        #expect(CitationLinkAction(url: URL(string: "https://example.com")!, currentMeetingID: "A") == nil)
    }

    // MARK: Speaker suggestions

    @Test func pendingSuggestionsNeedAClusterRowAndNoSegments() {
        let participants = [
            Participant(id: 1, meetingID: "m", displayName: "Speaker 1", source: .cluster, clusterLabel: "Speaker 1"),
            Participant(id: 2, meetingID: "m", displayName: "Priya", source: .llmSuggested, clusterLabel: "Speaker 1"),
            // no cluster row
            Participant(id: 3, meetingID: "m", displayName: "Raj", source: .calendar, clusterLabel: "Speaker 2"),
            // has segments
            Participant(id: 4, meetingID: "m", displayName: "Ann", source: .zoomAX, clusterLabel: "Speaker 1"),
        ]
        let pending = SpeakerSuggestion.pending(
            participants: participants, segments: [seg(10, .system, 0, 1, participant: 4)])
        #expect(pending.map(\.suggested.id) == [2])
        #expect(pending.first?.cluster.id == 1)
        #expect(pending.first?.clusterLabel == "Speaker 1")
    }

    @Test func confirmingASuggestionMovesSegmentsAndDismissDeletesOrClears() async throws {
        let (store, _) = try makeTempStore()
        let m = try await store.createMeeting(title: "T", startedBy: .manual)
        func insert(_ name: String, _ source: ParticipantSource, _ label: String) async throws -> Participant {
            try await store.pool.write { db in
                var participant = Participant(meetingID: m.id, displayName: name, source: source, clusterLabel: label)
                try participant.insert(db)
                return participant
            }
        }
        let cluster = try await insert("Speaker 1", .cluster, "Speaker 1")
        let suggested = try await insert("Priya", .llmSuggested, "Speaker 1")
        let calendar = try await insert("Raj", .calendar, "Speaker 2")
        let rows = try await store.appendSegments([
            Segment(
                meetingID: m.id, channel: .system, tStartMs: 0, tEndMs: 1, text: "a", participantID: cluster.id,
                pass: .final)
        ])

        let kept = try await store.confirmSpeakerSuggestion(suggestedID: suggested.id!, clusterID: cluster.id!)
        #expect(kept.clusterLabel == nil)
        #expect(try await store.segments(ids: [rows[0].id!]).first?.participantID == suggested.id)
        var names = try await store.participants(meetingID: m.id).map(\.displayName)
        #expect(names == ["Priya", "Raj"])

        try await store.dismissSpeakerSuggestion(suggestedID: calendar.id!)
        let raj = try await store.participants(meetingID: m.id).first { $0.displayName == "Raj" }
        #expect(raj?.clusterLabel == nil)

        let another = try await insert("Guess", .llmSuggested, "Speaker 3")
        try await store.dismissSpeakerSuggestion(suggestedID: another.id!)
        names = try await store.participants(meetingID: m.id).map(\.displayName)
        #expect(names == ["Priya", "Raj"])
    }

    @Test func titleAndConsentEditsTouchOnlyTheirColumns() async throws {
        let (store, _) = try makeTempStore()
        let m = try await store.createMeeting(title: "Old", startedBy: .manual)
        try await store.setProcessingStep(meetingID: m.id, step: "reindex")
        try await store.renameMeeting(id: m.id, to: "New")
        try await store.setConsentConfirmed(meetingID: m.id)
        let stored = try #require(try await store.meeting(id: m.id))
        #expect(stored.title == "New")
        #expect(stored.consentConfirmed)
        #expect(stored.processingStep == "reindex")
    }
}
