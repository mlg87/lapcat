import Foundation
import LapCatCore
import LapCatLLM
import LapCatSpeech
import Testing

@testable import LapCatSession

/// Records every request and answers each with a fixed enhanced note.
private final class RecordingProvider: LLMProvider, @unchecked Sendable {
    let id: String
    let displayName = "Recording"
    let contextBudgetTokens = 150_000
    private let lock = NSLock()
    private var recorded: [LLMRequest] = []

    init(id: String) { self.id = id }

    var requests: [LLMRequest] { lock.withLock { recorded } }

    func isAvailable() async -> Bool { true }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        lock.withLock { recorded.append(request) }
        return LLMResponse(text: "## Summary\n- Pricing agreed", provider: id, model: "recording")
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

struct PostMeetingPipelineQuickEnhanceTests {
    /// Runs `steps` over a meeting with raw notes, routed to `provider`; returns the final status and store.
    private func run(provider: RecordingProvider, steps: [PostMeetingPipeline.Step]) async throws
        -> (status: MeetingStatus?, store: Store, meetingID: String)
    {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lapcat-pipeline-\(UUID().uuidString)")
        let store = try Store(databaseURL: dir.appendingPathComponent("db.sqlite"))
        try await TemplateLibrary.sync(store: store, customDirectory: dir.appendingPathComponent("templates"))
        // A non-default title keeps the enhancer from making an auto-title call on the provider.
        let meeting = try await store.createMeeting(title: "Pricing sync", startedBy: .manual)
        try await store.saveRawNote(meetingID: meeting.id, markdown: "raw line kept")
        let config = PipelineConfig(
            speech: SpeechConfig(modelsDirectory: dir.appendingPathComponent("models")), offlineOnly: false,
            retention: .never, meName: "Mason", defaultTemplateID: "general", autoExportFolder: nil,
            router: LLMRouter(providers: [provider], offlineOnly: false))
        let pipeline = PostMeetingPipeline(
            store: store, speech: SpeechServices(), paths: Paths(root: dir), steps: steps, config: { config })
        await pipeline.enqueue(meeting.id)
        var status: MeetingStatus?
        for _ in 0..<500 {
            status = try await store.meeting(id: meeting.id)?.status
            if status == .ready || status == .error { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return (status, store, meeting.id)
    }

    @Test func localEnhanceHeadSkipsQuickEnhanceAndFinalEnhanceStillRuns() async throws {
        let local = RecordingProvider(id: LLMRouter.localProviderID)
        let (status, store, meetingID) = try await run(provider: local, steps: [.quickEnhance, .enhance])
        #expect(status == .ready)
        // Only the final enhance reached the provider: quick_enhance made no request.
        #expect(local.requests.count == 1)
        #expect(try await store.enhancedNotes(meetingID: meetingID).count == 1)
    }

    @Test func remoteEnhanceHeadStillRunsQuickEnhance() async throws {
        let remote = RecordingProvider(id: "claude-cli")
        let (status, store, meetingID) = try await run(provider: remote, steps: [.quickEnhance])
        #expect(status == .ready)
        #expect(remote.requests.count == 1)
        #expect(try await store.enhancedNotes(meetingID: meetingID).count == 1)
    }
}
