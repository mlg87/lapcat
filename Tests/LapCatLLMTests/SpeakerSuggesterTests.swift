import Foundation
import Testing
@testable import LapCatLLM

/// Replies with a fixed text and records the request it received.
private final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let id = "local"
    let displayName = "Local"
    let contextBudgetTokens = 24_000
    private let reply: String
    private let lock = NSLock()
    private var _requests: [LLMRequest] = []

    init(reply: String) { self.reply = reply }

    var requests: [LLMRequest] { lock.withLock { _requests } }

    func isAvailable() async -> Bool { true }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        lock.withLock { _requests.append(request) }
        return LLMResponse(text: reply, provider: id, model: "test")
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite struct SpeakerSuggesterTests {
    private func suggest(
        reply: String, clusters: [String] = ["Speaker 1", "Speaker 2"],
        candidates: [String] = ["Priya Shah", "Tom Lee"]
    ) async throws -> ([SpeakerSuggester.Suggestion], ScriptedProvider) {
        let provider = ScriptedProvider(reply: reply)
        let router = LLMRouter(providers: [provider], offlineOnly: false)
        let result = try await SpeakerSuggester.suggest(
            router: router, transcript: "[12] 00:00:05 Speaker 1: Thanks Tom.", clusters: clusters,
            candidates: candidates)
        return (result, provider)
    }

    @Test func decodesFencedReplyAsClassifyTask() async throws {
        let reply = """
            Here you go:
            ```json
            {"suggestions":[{"cluster":"Speaker 2","name":"Tom Lee","evidence_segment_id":12},{"cluster":"Speaker 1","name":"Priya Shah","evidence_segment_id":"40"}]}
            ```
            """
        let (suggestions, provider) = try await suggest(reply: reply)
        #expect(
            suggestions == [
                .init(cluster: "Speaker 2", name: "Tom Lee", evidenceSegmentID: 12),
                .init(cluster: "Speaker 1", name: "Priya Shah", evidenceSegmentID: 40),
            ])
        let request = try #require(provider.requests.first)
        #expect(request.task == .classify)
        #expect(request.expectJSON)
        #expect(request.system == SpeakerSuggester.system)
    }

    @Test func dropsUnknownNamesUnrequestedClustersAndDuplicates() async throws {
        let reply = #"""
            {"suggestions":[
              {"cluster":"Speaker 1","name":"priya shah","evidence_segment_id":3},
              {"cluster":"Speaker 1","name":"Tom Lee","evidence_segment_id":4},
              {"cluster":"Speaker 2","name":"Priya Shah","evidence_segment_id":5},
              {"cluster":"Speaker 3","name":"Tom Lee","evidence_segment_id":6},
              {"cluster":"Speaker 2","name":"Alex Kim"}
            ]}
            """#
        let (suggestions, _) = try await suggest(reply: reply)
        // Canonical candidate spelling; Speaker 1 suggested once; Priya not reused; Speaker 3 not asked; Alex not a candidate.
        #expect(suggestions == [.init(cluster: "Speaker 1", name: "Priya Shah", evidenceSegmentID: 3)])
    }

    @Test func emptyInputsSkipTheLLM() async throws {
        let (suggestions, provider) = try await suggest(reply: "{}", candidates: [])
        #expect(suggestions.isEmpty)
        #expect(provider.requests.isEmpty)
    }

    @Test func undecodableReplyThrowsInvalidResponse() async {
        await #expect(throws: LLMError.invalidResponse("no decodable JSON object in reply")) {
            _ = try await suggest(reply: "Speaker 1 is probably Tom.")
        }
    }
}
