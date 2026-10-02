import Foundation
import LapCatCore
import Testing
@testable import LapCatLLM

/// Scripted provider: answers by system prompt, records every request.
private final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let id: String
    let displayName = "Scripted"
    let contextBudgetTokens: Int
    private let lock = NSLock()
    private var recorded: [LLMRequest] = []
    private let reply: @Sendable (LLMRequest) throws -> String

    init(id: String = "claude-cli", budget: Int, reply: @escaping @Sendable (LLMRequest) throws -> String) {
        self.id = id
        contextBudgetTokens = budget
        self.reply = reply
    }

    var requests: [LLMRequest] { lock.withLock { recorded } }

    func isAvailable() async -> Bool { true }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        lock.withLock { recorded.append(request) }
        return LLMResponse(text: try reply(request), provider: id, model: "test-model")
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct Fixture {
    let store: Store
    let meeting: Meeting
    let segments: [Segment]
}

struct EnhancerTests {
    private static let enhanced = "## Summary\n- We agreed on pricing [[s:1]] [[s:424242]]\nraw line kept"

    private static func reply(classify: String = #"{"template_id":"one-on-one"}"#, title: String = #"{"title":"Pricing sync"}"#) -> @Sendable (LLMRequest) throws -> String {
        { request in
            switch request.system {
            case Prompts.enhanceSystem: return enhanced
            case Prompts.chunkSummarySystem: return "- summary of \(request.messages[0].content.prefix(12)) [[s:1]]"
            case Prompts.titleSystem: return title
            default:
                if request.task == .classify { return classify }
                throw LLMError.invalidResponse("unexpected request")
            }
        }
    }

    /// Meeting with `minutes` of system-channel segments every 5 s (~140 chars each), plus raw notes.
    private func fixture(minutes: Int, title: String = "Note 2026-10-01 14:05", calendar: Bool = false) async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lapcat-enhancer-\(UUID().uuidString)")
        let store = try Store(databaseURL: dir.appendingPathComponent("db.sqlite"))
        try await TemplateLibrary.sync(store: store, customDirectory: dir.appendingPathComponent("templates"))
        let meeting = try await store.createMeeting(title: title, startedBy: .manual)
        let filler = String(repeating: "we talked about the pricing model and the rollout plan ", count: 2)
        let segments = try await store.appendSegments((0..<(minutes * 12)).map { i in
            Segment(meetingID: meeting.id, channel: i.isMultiple(of: 7) ? .mic : .system, tStartMs: i * 5_000, tEndMs: i * 5_000 + 4_000,
                    text: "\(filler)\(i)", pass: .final)
        })
        try await store.saveRawNote(meetingID: meeting.id, markdown: "raw line kept")
        if calendar {
            try await store.saveCalendarSnapshot(CalendarSnapshot(meetingID: meeting.id, eventTitle: "Pricing", attendees: ["Priya"]))
        }
        return Fixture(store: store, meeting: meeting, segments: segments)
    }

    @Test func overBudgetTranscriptTakesMapReduceWithOneCallPerTenMinuteWindow() async throws {
        let f = try await fixture(minutes: 70)
        let provider = ScriptedProvider(budget: 24_000, reply: Self.reply())
        let enhancer = Enhancer(store: f.store, router: LLMRouter(providers: [provider], offlineOnly: false))

        _ = try await enhancer.enhance(meetingID: f.meeting.id, templateID: "general")

        let requests = provider.requests
        let maps = requests.filter { $0.system == Prompts.chunkSummarySystem }
        #expect(maps.count == 7)
        let reduce = try #require(requests.first { $0.system == Prompts.enhanceSystem })
        let prompt = reduce.messages[0].content
        #expect(prompt.contains("# Transcript summaries (by 10-minute window, with segment citations)"))
        #expect(!prompt.contains("\n# Transcript\n"))
        for map in maps {
            #expect(prompt.contains("- summary of \(map.messages[0].content.prefix(12)) [[s:1]]"))
        }
        // Each window holds exactly its own 10 minutes: 120 segments at 5 s spacing.
        #expect(maps.allSatisfy { $0.messages[0].content.split(separator: "\n").count == 120 })
        #expect(Set(maps.map { $0.messages[0].content.prefix(4) }).count == 7)
    }

    @Test func underBudgetTranscriptIsOneEnhanceCall() async throws {
        let f = try await fixture(minutes: 70)
        let provider = ScriptedProvider(budget: 150_000, reply: Self.reply())
        let enhancer = Enhancer(store: f.store, router: LLMRouter(providers: [provider], offlineOnly: false))

        let note = try await enhancer.enhance(meetingID: f.meeting.id, templateID: "general")

        let enhanceCalls = provider.requests.filter { $0.task == .enhance }
        #expect(enhanceCalls.count == 1)
        let prompt = enhanceCalls[0].messages[0].content
        #expect(prompt.contains("# Template: General meeting"))
        #expect(prompt.contains("# My raw notes\nraw line kept"))
        #expect(prompt.contains("\n# Transcript\n[\(f.segments[0].id!)] 00:00:00 Me: "))
        #expect(note.markdown == Self.enhanced)
        #expect(note.basedOnPass == .final)
        // [[s:424242]] is not a segment of this meeting and is dropped.
        let citations = try JSONDecoder().decode([Citation].self, from: Data(note.citationsJSON.utf8))
        #expect(citations == [Citation(lineIndex: 1, segmentIDs: [1])])
        let meeting = try #require(try await f.store.meeting(id: f.meeting.id))
        #expect(meeting.templateID == "general")
        #expect(meeting.llmProviderUsed == "claude-cli:test-model")
    }

    @Test func autoUsesClassifierChoiceAndFallsBackToGeneralWhenClassifyThrows() async throws {
        let f = try await fixture(minutes: 2)
        let picking = ScriptedProvider(budget: 150_000, reply: Self.reply())
        let note = try await Enhancer(store: f.store, router: LLMRouter(providers: [picking], offlineOnly: false))
            .enhance(meetingID: f.meeting.id, templateID: TemplateLibrary.autoID)
        #expect(note.templateID == "one-on-one")

        let failing = ScriptedProvider(budget: 150_000) { request in
            if request.task == .classify, request.system != Prompts.titleSystem { throw LLMError.invalidResponse("boom") }
            return try Self.reply()(request)
        }
        let fallback = try await Enhancer(store: f.store, router: LLMRouter(providers: [failing], offlineOnly: false))
            .enhance(meetingID: f.meeting.id, templateID: TemplateLibrary.autoID)
        #expect(fallback.templateID == "general")
        #expect(fallback.version == note.version + 1)

        let unknown = ScriptedProvider(budget: 150_000, reply: Self.reply(classify: #"{"template_id":"nope"}"#))
        let unknownPick = try await Enhancer(store: f.store, router: LLMRouter(providers: [unknown], offlineOnly: false))
            .enhance(meetingID: f.meeting.id, templateID: TemplateLibrary.autoID)
        #expect(unknownPick.templateID == "general")
    }

    @Test func autoTitleOnlyForDefaultTitleWithoutCalendarSnapshot() async throws {
        let cases: [(title: String, calendar: Bool, expected: String)] = [
            ("Note 2026-10-01 14:05", false, "Pricing sync"),
            ("Note 2026-10-01 14:05", true, "Note 2026-10-01 14:05"),
            ("Weekly with Priya", false, "Weekly with Priya"),
        ]
        for c in cases {
            let f = try await fixture(minutes: 1, title: c.title, calendar: c.calendar)
            let provider = ScriptedProvider(budget: 150_000, reply: Self.reply())
            _ = try await Enhancer(store: f.store, router: LLMRouter(providers: [provider], offlineOnly: false))
                .enhance(meetingID: f.meeting.id, templateID: "general")
            #expect(try await f.store.meeting(id: f.meeting.id)?.title == c.expected, "\(c)")
            #expect(provider.requests.contains { $0.system == Prompts.titleSystem } == (c.expected != c.title))
        }
    }

    @Test func providerOverrideRoutesOnlyToThatProvider() async throws {
        let f = try await fixture(minutes: 1)
        let first = ScriptedProvider(id: "claude-cli", budget: 150_000, reply: Self.reply())
        let local = ScriptedProvider(id: "local", budget: 24_000, reply: Self.reply())
        let note = try await Enhancer(store: f.store, router: LLMRouter(providers: [first, local], offlineOnly: false))
            .enhance(meetingID: f.meeting.id, templateID: "general", providerOverride: "local")
        #expect(note.provider == "local")
        #expect(first.requests.isEmpty)
    }

    @Test func emptyMeetingAndUnknownTemplateAreErrors() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lapcat-enhancer-\(UUID().uuidString)")
        let store = try Store(databaseURL: dir.appendingPathComponent("db.sqlite"))
        let meeting = try await store.createMeeting(title: "Empty", startedBy: .manual)
        let provider = ScriptedProvider(budget: 150_000, reply: Self.reply())
        let enhancer = Enhancer(store: store, router: LLMRouter(providers: [provider], offlineOnly: false))
        await #expect(throws: EnhancerError.nothingToEnhance) {
            try await enhancer.enhance(meetingID: meeting.id, templateID: "general")
        }
        try await store.saveRawNote(meetingID: meeting.id, markdown: "a note")
        await #expect(throws: EnhancerError.templateNotFound("general")) {
            try await enhancer.enhance(meetingID: meeting.id, templateID: "general")
        }
        #expect(provider.requests.isEmpty)
    }

    @Test func windowsGroupByTenMinutesSkippingEmptyOnes() {
        let segments = [0, 599_999, 600_000, 2_500_000].enumerated().map { i, ms in
            Segment(id: Int64(i), meetingID: "m", channel: .system, tStartMs: ms, tEndMs: ms + 1, text: "t", pass: .final)
        }
        let windows = Enhancer.windows(segments)
        #expect(windows.map(\.index) == [0, 1, 4])
        #expect(windows.map(\.segments.count) == [2, 1, 1])
    }
}
