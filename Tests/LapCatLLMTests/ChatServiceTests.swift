import Foundation
import LapCatCore
import Testing
@testable import LapCatLLM

/// Streams fixed deltas and records the requests it received.
private final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let id = "claude-cli"
    let displayName = "Claude via CLI"
    let contextBudgetTokens: Int
    let deltas: [String]
    let failAfterFirstDelta: Bool
    private let lock = NSLock()
    private var _requests: [LLMRequest] = []
    var requests: [LLMRequest] { lock.withLock { _requests } }

    init(budget: Int = 150_000, deltas: [String], failAfterFirstDelta: Bool = false) {
        contextBudgetTokens = budget
        self.deltas = deltas
        self.failAfterFirstDelta = failAfterFirstDelta
    }

    func isAvailable() async -> Bool { true }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: deltas.joined(), provider: id, model: "m")
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _requests.append(request) }
        let deltas = deltas
        let fail = failAfterFirstDelta
        return AsyncThrowingStream { continuation in
            for (index, delta) in deltas.enumerated() {
                continuation.yield(delta)
                if fail, index == 0 {
                    continuation.finish(throwing: LLMError.invalidResponse("boom"))
                    return
                }
            }
            continuation.finish()
        }
    }
}

private func makeStore() throws -> Store {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lapcat-tests-\(UUID().uuidString)")
    return try Store(databaseURL: dir.appendingPathComponent("lapcat.sqlite"))
}

private func makeService(_ store: Store, _ provider: ScriptedProvider) -> ChatService {
    ChatService(store: store, router: LLMRouter(providers: [provider], offlineOnly: false))
}

@Suite struct ChatServiceTests {
    @Test func meetingContextDropsOldestLinesFirstAndMarksOmission() {
        let lines = (1...10).map { "[\($0)] 00:00:0\($0 % 10) Them: line number \($0)" }
        let full = ChatService.meetingContext(
            title: "Sync", date: "2026-09-30", enhancedNote: "## Notes\n- a", transcriptLines: lines, budgetChars: 100_000)
        #expect(!full.contains(ChatService.omittedMarker))
        #expect(full.contains("# Enhanced notes\n## Notes\n- a"))
        #expect(full.hasSuffix(lines.joined(separator: "\n")))

        let header = ChatService.meetingContext(
            title: "Sync", date: "2026-09-30", enhancedNote: "## Notes\n- a", transcriptLines: [], budgetChars: 100_000)
            .replacingOccurrences(of: "(no transcript)", with: "")
        let budget = header.count + ChatService.omittedMarker.count + 1 + 3 * (lines[0].count + 1)
        let truncated = ChatService.meetingContext(
            title: "Sync", date: "2026-09-30", enhancedNote: "## Notes\n- a", transcriptLines: lines, budgetChars: budget)
        #expect(truncated.count <= budget)
        #expect(truncated.contains("# Enhanced notes\n## Notes\n- a"))
        let transcript = truncated.components(separatedBy: "# Transcript\n")[1].components(separatedBy: "\n")
        #expect(transcript.first == ChatService.omittedMarker)
        // Only the newest lines survive, in chronological order.
        #expect(Array(transcript.dropFirst()) == Array(lines.suffix(transcript.count - 1)))
        #expect(transcript.count - 1 >= 2)
        #expect(!truncated.contains("line number 1\n"))
    }

    @Test func meetingScopeContextUsesFinalPassSpeakerNamesAndSkipsEchoes() async throws {
        let store = try makeStore()
        let meeting = try await store.createMeeting(title: "Sync", startedBy: .manual)
        let priya = try await store.upsertParticipant(meetingID: meeting.id, name: "Priya", source: .zoomAX)
        let saved = try await store.appendSegments([
            Segment(meetingID: meeting.id, channel: .system, tStartMs: 61_000, tEndMs: 62_000, text: "We ship Friday", participantID: priya.id, pass: .final),
            Segment(meetingID: meeting.id, channel: .mic, tStartMs: 63_000, tEndMs: 64_000, text: "I'll write the notes", pass: .final),
            Segment(meetingID: meeting.id, channel: .mic, tStartMs: 61_500, tEndMs: 62_000, text: "We ship Friday", pass: .final, isEchoDuplicate: true),
            Segment(meetingID: meeting.id, channel: .system, tStartMs: 0, tEndMs: 1, text: "live only", pass: .live),
        ])
        let context = try await makeService(store, ScriptedProvider(deltas: [])).context(
            scope: .meeting, scopeRef: meeting.id, question: "q", dateRange: nil, budgetChars: 100_000)
        #expect(context.hasSuffix("""
            # Transcript
            [\(saved[0].id!)] 00:01:01 Priya: We ship Friday
            [\(saved[1].id!)] 00:01:03 Me: I'll write the notes
            """))
        #expect(!context.contains("live only"))
    }

    @Test func globalContextFormatsHitsWithNeighboursAndMeetingCitations() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let meeting = try await store.createMeeting(title: "Pricing sync", startedBy: .manual, now: start)
        let other = try await store.createMeeting(title: "Roadmap", startedBy: .manual, now: start)
        let priya = try await store.upsertParticipant(meetingID: meeting.id, name: "Priya", source: .zoomAX)
        let texts = ["intro", "weather talk", "agenda", "budget review", "the discount stays at ten percent", "next topic", "hiring", "wrap up"]
        let segs = try await store.appendSegments(texts.enumerated().map { index, text in
            Segment(meetingID: meeting.id, channel: index.isMultiple(of: 2) ? .mic : .system, tStartMs: index * 10_000, tEndMs: index * 10_000 + 5_000,
                    text: text, participantID: index.isMultiple(of: 2) ? nil : priya.id, pass: .final)
        })
        let otherSegs = try await store.appendSegments([
            Segment(meetingID: other.id, channel: .system, tStartMs: 0, tEndMs: 1_000, text: "discount for partners", pass: .final),
        ])
        try await store.insertEnhancedNote(EnhancedNote(
            meetingID: other.id, templateID: "general", provider: "p", model: "m",
            markdown: "- Partner discount approved [[s:\(otherSegs[0].id!)]]", basedOnPass: .final, createdAt: start))
        try await store.reindexFTS(meetingID: meeting.id)
        try await store.reindexFTS(meetingID: other.id)

        let context = try await makeService(store, ScriptedProvider(deltas: [])).context(
            scope: .global, scopeRef: nil, question: "What was the discount?", dateRange: nil, budgetChars: 100_000)
        let day = ChatService.dayString(start)
        let id = { (i: Int) in segs[i].id! }
        // Hit = "the discount stays…" (index 4) with ±2 neighbours (indexes 2…6), Me/Priya speakers.
        #expect(context.contains("""
            [[m:\(meeting.id)#s:\(id(2))]] Pricing sync, \(day) Me: agenda
            [[m:\(meeting.id)#s:\(id(3))]] Pricing sync, \(day) Priya: budget review
            [[m:\(meeting.id)#s:\(id(4))]] Pricing sync, \(day) Me: the discount stays at ten percent
            [[m:\(meeting.id)#s:\(id(5))]] Pricing sync, \(day) Priya: next topic
            [[m:\(meeting.id)#s:\(id(6))]] Pricing sync, \(day) Me: hiring
            """))
        #expect(!context.contains("weather talk"))
        #expect(!context.contains("wrap up"))
        // Enhanced-note hits carry their citations rewritten to the cross-meeting form.
        #expect(context.contains("Partner discount approved [[m:\(other.id)#s:\(otherSegs[0].id!)]]"))
        #expect(context.contains("[[m:\(other.id)#s:\(otherSegs[0].id!)]] Roadmap, \(day) Them: discount for partners"))

        let folder = try await store.createFolder(name: "Sales")
        try await store.setFolder(meetingID: other.id, folderID: folder.id)
        let scoped = try await makeService(store, ScriptedProvider(deltas: [])).context(
            scope: .folder, scopeRef: folder.id, question: "discount", dateRange: nil, budgetChars: 100_000)
        #expect(scoped.contains("Roadmap"))
        #expect(!scoped.contains("Pricing sync"))
    }

    @Test func questionNamingAParticipantIncludesWhatTheySaid() async throws {
        let store = try makeStore()
        let meeting = try await store.createMeeting(title: "Sync", startedBy: .manual)
        let priya = try await store.upsertParticipant(meetingID: meeting.id, name: "Priya Shah", source: .zoomAX)
        let segs = try await store.appendSegments([
            Segment(meetingID: meeting.id, channel: .system, tStartMs: 0, tEndMs: 1, text: "I'll send the deck Thursday", participantID: priya.id, pass: .final),
            Segment(meetingID: meeting.id, channel: .mic, tStartMs: 2, tEndMs: 3, text: "Sounds good", pass: .final),
        ])
        try await store.reindexFTS(meetingID: meeting.id)
        let context = try await makeService(store, ScriptedProvider(deltas: [])).context(
            scope: .global, scopeRef: nil, question: "What did Priya commit to?", dateRange: nil, budgetChars: 100_000)
        #expect(context.contains("[[m:\(meeting.id)#s:\(segs[0].id!)]] Sync, \(ChatService.dayString(meeting.startedAt)) Priya Shah: I'll send the deck Thursday"))
        #expect(!context.contains("Sounds good"))
    }

    @Test func askStreamsDeltasAndPersistsBothMessagesWithValidCitations() async throws {
        let store = try makeStore()
        let meeting = try await store.createMeeting(title: "Sync", startedBy: .manual)
        let seg = try await store.appendSegments([
            Segment(meetingID: meeting.id, channel: .system, tStartMs: 0, tEndMs: 1_000, text: "We ship Friday", pass: .final),
        ])[0]
        let provider = ScriptedProvider(deltas: ["They ship ", "Friday [[s:\(seg.id!)]]", " [[s:999]]\nDone."])
        let service = makeService(store, provider)

        var received: [String] = []
        for try await delta in service.ask(scope: .meeting, scopeRef: meeting.id, question: "When do we ship?") {
            received.append(delta)
        }
        #expect(received == provider.deltas)

        let thread = try await store.thread(for: .meeting, scopeRef: meeting.id)
        let messages = try await store.messages(threadID: thread.id)
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages[0].content == "When do we ship?")
        #expect(messages[1].content == provider.deltas.joined())
        #expect(messages[1].provider == "claude-cli")
        let citations = try JSONDecoder().decode([ChatCitations.Citation].self, from: Data(messages[1].citationsJSON.utf8))
        #expect(citations == [ChatCitations.Citation(lineIndex: 0, segmentIDs: [seg.id!], meetingSegments: [])])

        let request = try #require(provider.requests.first)
        #expect(request.task == .chat)
        #expect(request.system == ChatService.chatSystem)
        #expect(request.messages.count == 1)
        #expect(request.messages[0].content.hasSuffix("# Question\nWhen do we ship?"))
        #expect(request.messages[0].content.contains("[\(seg.id!)] 00:00:00 Them: We ship Friday"))
    }

    @Test func followUpIncludesOnlyTheLastTenPriorMessages() async throws {
        let store = try makeStore()
        let thread = try await store.thread(for: .global)
        for i in 0..<12 {
            try await store.appendChatMessage(ChatMessage(
                threadID: thread.id, role: i.isMultiple(of: 2) ? .user : .assistant, content: "m\(i)", createdAt: Date()))
        }
        let provider = ScriptedProvider(deltas: ["ok"])
        for try await _ in makeService(store, provider).ask(scope: .global, scopeRef: nil, question: "next?") {}
        let messages = try #require(provider.requests.first).messages
        #expect(messages.dropLast().map(\.content) == (2..<12).map { "m\($0)" })
        #expect(messages.last?.content.hasSuffix("# Question\nnext?") == true)
    }

    @Test func failedStreamKeepsUserMessageButNoAssistantMessage() async throws {
        let store = try makeStore()
        let provider = ScriptedProvider(deltas: ["partial", "rest"], failAfterFirstDelta: true)
        await #expect(throws: LLMError.invalidResponse("boom")) {
            for try await _ in makeService(store, provider).ask(scope: .global, scopeRef: nil, question: "q") {}
        }
        let thread = try await store.thread(for: .global)
        #expect(try await store.messages(threadID: thread.id).map(\.role) == [.user])
    }

    @Test func crossMeetingCitationsAreValidatedAgainstTheirMeeting() async throws {
        let store = try makeStore()
        let a = try await store.createMeeting(title: "A", startedBy: .manual)
        let b = try await store.createMeeting(title: "B", startedBy: .manual)
        let segA = try await store.appendSegments([Segment(meetingID: a.id, channel: .mic, tStartMs: 0, tEndMs: 1, text: "x", pass: .final)])[0]
        let service = makeService(store, ScriptedProvider(deltas: []))
        let json = try await service.citationsJSON(
            "Yes [[m:\(a.id)#s:\(segA.id!)]] and [[m:\(b.id)#s:\(segA.id!)]]\nno cite", scope: .global, scopeRef: nil)
        let citations = try JSONDecoder().decode([ChatCitations.Citation].self, from: Data(json.utf8))
        #expect(citations == [ChatCitations.Citation(
            lineIndex: 0, segmentIDs: [], meetingSegments: [.init(meetingID: a.id, segmentID: segA.id!)])])
    }
}
