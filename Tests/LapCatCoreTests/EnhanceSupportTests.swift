import Foundation
import Testing
@testable import LapCatCore

struct TemplateLibraryTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lapcat-templates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func frontmatterGivesNameDescriptionAndBody() {
        let doc = TemplateDocument(
            parsing: "---\nname: \"Sales call\"\ndescription: For prospects: discovery\n---\n\n## Needs\n<!-- list -->\n",
            fallbackName: "sales")
        #expect(doc.name == "Sales call")
        #expect(doc.description == "For prospects: discovery")
        #expect(doc.body == "## Needs\n<!-- list -->")
    }

    @Test func missingFrontmatterUsesStemAndWholeText() {
        let doc = TemplateDocument(parsing: "## Notes\n---\nnot frontmatter", fallbackName: "plain")
        #expect(doc.name == "plain")
        #expect(doc.description == "")
        #expect(doc.body == "## Notes\n---\nnot frontmatter")
    }

    @Test func unterminatedFrontmatterIsBody() {
        let doc = TemplateDocument(parsing: "---\nname: X\n## Notes", fallbackName: "stem")
        #expect(doc.name == "stem")
        #expect(doc.body == "---\nname: X\n## Notes")
    }

    @Test func builtinsShipSixTemplatesWithSections() throws {
        let builtins = try TemplateLibrary.builtinTemplates()
        #expect(Set(builtins.map(\.id)) == ["general", "one-on-one", "standup", "customer-call", "interview", "project-review"])
        for template in builtins {
            #expect(template.isBuiltin)
            #expect(template.hasSections, "\(template.id)")
            #expect(!template.name.isEmpty && !template.description.isEmpty)
        }
    }

    @Test func syncAddsUpdatesAndRemovesCustomTemplates() async throws {
        let store = try Store(databaseURL: try tempDir().appendingPathComponent("db.sqlite"))
        let custom = try tempDir()
        try "---\nname: Board\n---\n## Agenda".write(to: custom.appendingPathComponent("board.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: custom.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        try await TemplateLibrary.sync(store: store, customDirectory: custom)
        var rows = try await store.templates()
        #expect(rows.filter(\.isBuiltin).count == 6)
        let board = try #require(rows.first { $0.id == "custom:board" })
        #expect(!board.isBuiltin)
        #expect(board.name == "Board")
        #expect(board.filePath == custom.appendingPathComponent("board.md").path)

        try FileManager.default.removeItem(at: custom.appendingPathComponent("board.md"))
        try "## Retro".write(to: custom.appendingPathComponent("retro.md"), atomically: true, encoding: .utf8)
        try await TemplateLibrary.sync(store: store, customDirectory: custom)
        rows = try await store.templates()
        #expect(rows.filter { !$0.isBuiltin }.map(\.id) == ["custom:retro"])
        #expect(rows.filter(\.isBuiltin).count == 6)
    }

    @Test func missingCustomDirectoryKeepsBuiltinsOnly() async throws {
        let store = try Store(databaseURL: try tempDir().appendingPathComponent("db.sqlite"))
        try await TemplateLibrary.sync(store: store, customDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(try await store.templates().count == 6)
    }
}

private extension Template {
    var hasSections: Bool { bodyMarkdown.contains("\n## ") || bodyMarkdown.hasPrefix("## ") }
}

struct TranscriptFormatterTests {
    private let meeting = "m1"

    private func seg(_ id: Int64, _ channel: Channel, _ ms: Int, _ text: String, pass: SegmentPass = .final, participant: Int64? = nil, volatile: Bool = false, echo: Bool = false) -> Segment {
        Segment(id: id, meetingID: meeting, channel: channel, tStartMs: ms, tEndMs: ms + 1000, text: text,
                participantID: participant, pass: pass, isVolatile: volatile, isEchoDuplicate: echo)
    }

    @Test func linesUseIdTimestampAndSpeakerFallbacks() {
        let priya = Participant(id: 7, meetingID: meeting, displayName: "Priya Shah", source: .zoomAX)
        let text = TranscriptFormatter.forLLM(
            segments: [
                seg(3, .system, 3_725_400, "Pricing is\nfine.", participant: 7),
                seg(1, .mic, 0, " Hello "),
                seg(2, .system, 61_000, "Hi there"),
            ],
            participants: [priya])
        #expect(text == """
            [1] 00:00:00 Me: Hello
            [2] 00:01:01 Them: Hi there
            [3] 01:02:05 Priya Shah: Pricing is fine.
            """)
    }

    @Test func finalPassWinsOverLiveAndVolatileAndEchoAreDropped() {
        let segments = [
            seg(1, .mic, 0, "live words", pass: .live),
            seg(2, .mic, 0, "final words"),
            seg(3, .system, 500, "echo", echo: true),
            seg(4, .system, 900, "hypothesis", pass: .live, volatile: true),
        ]
        #expect(TranscriptFormatter.forLLM(segments: segments, participants: []) == "[2] 00:00:00 Me: final words")
        #expect(TranscriptFormatter.selectedPass(segments) == .final)
    }

    @Test func liveIsUsedWhenOnlyEchoOrVolatileFinalsExist() {
        let segments = [
            seg(1, .mic, 0, "live words", pass: .live),
            seg(2, .system, 0, "echoed final", echo: true),
        ]
        #expect(TranscriptFormatter.forLLM(segments: segments, participants: []) == "[1] 00:00:00 Me: live words")
        #expect(TranscriptFormatter.selectedPass(segments) == .live)
    }
}

struct CitationsTests {
    @Test func bareIDsOfKnownSegmentsBecomeSegmentCitationsOthersAreLeftAlone() {
        let markdown = "- Ships Friday [[117]][[118]] and [[s:119]]\n- Footnote [[9999]] stays; [117] is not a marker"
        let normalized = Citations.normalizingBareSegmentIDs(markdown, validSegmentIDs: [117, 118, 119])
        #expect(normalized == "- Ships Friday [[s:117]][[s:118]] and [[s:119]]\n- Footnote [[9999]] stays; [117] is not a marker")
        #expect(Citations.parse(normalized, validSegmentIDs: [117, 118, 119]).first?.segmentIDs == [117, 118, 119])
    }

    @Test func parsesPerLineAndDropsUnknownIds() {
        let markdown = """
            ## Decisions
            - Ship Friday [[s:12]][[s:13]]
            - Mystery claim [[s:999]]
            - Mixed [[s:12]] [[s:12]] [[s:abc]] [[s:14]]
            - Cross [[m:0F3A-11#s:5]]
            """
        let citations = Citations.parse(markdown, validSegmentIDs: [12, 13, 14])
        #expect(citations == [
            Citation(lineIndex: 1, segmentIDs: [12, 13]),
            Citation(lineIndex: 3, segmentIDs: [12, 14]),
            Citation(lineIndex: 4, segmentIDs: [], meetingSegments: [MeetingSegmentRef(meetingID: "0F3A-11", segmentID: 5)]),
        ])
    }

    @Test func overflowingIdIsNotACitation() {
        #expect(Citations.parse("x [[s:99999999999999999999]]").isEmpty)
    }

    @Test func linkifiedRoundTripsThroughTarget() throws {
        let linked = Citations.linkified("Done [[s:42]] and [[m:AB-12#s:7]], not [[s:x]]")
        #expect(linked == "Done [⌃42](lapcat://segment/42) and [⌃7](lapcat://meeting/AB-12/segment/7), not [[s:x]]")
        #expect(Citations.target(of: try #require(URL(string: "lapcat://segment/42"))) == .segment(42))
        #expect(Citations.target(of: try #require(URL(string: "lapcat://meeting/AB-12/segment/7")))
            == .meetingSegment(MeetingSegmentRef(meetingID: "AB-12", segmentID: 7)))
        #expect(Citations.target(of: try #require(URL(string: "https://segment/42"))) == nil)
        #expect(Citations.target(of: try #require(URL(string: "lapcat://segment/abc"))) == nil)
    }
}

struct LineAttributionTests {
    @Test func matchesUserLinesDespiteMarkersCaseSpacingAndCitations() {
        let raw = """
            pricing  ok
            - [ ] send deck to Priya
            * Q3 launch
            """
        let enhanced = """
            ## Decisions
            - Pricing ok
            - [x] Send deck  to priya [[s:4]]
            • q3 launch
            - Pricing ok for enterprise [[s:2]]

            """
        #expect(LineAttribution.classify(enhanced: enhanced, raw: raw) == [.ai, .mine, .mine, .mine, .ai, .ai])
    }

    @Test func emptyRawNotesMakeEverythingAI() {
        #expect(LineAttribution.classify(enhanced: "- a\n- b", raw: "\n  \n") == [.ai, .ai])
    }
}
