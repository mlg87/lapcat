import Foundation
import Testing
@testable import LapCatLLM

// MARK: - Claude CLI envelope

@Suite struct ClaudeCLIEnvelopeTests {
    @Test func successEnvelopeYieldsTextModelTokensAndCost() throws {
        let envelope = """
            {"type":"result","subtype":"success","is_error":false,"result":"OK","total_cost_usd":0.047,
             "usage":{"input_tokens":9,"cache_creation_input_tokens":100,"cache_read_input_tokens":1,"output_tokens":110},
             "modelUsage":{"claude-haiku-4-5-20251001":{"inputTokens":3,"outputTokens":2},
                           "claude-sonnet-5-5":{"inputTokens":9,"outputTokens":110}}}
            """
        let response = try ClaudeCLIProvider.parseEnvelope(Data(envelope.utf8), requestedModel: "sonnet")
        #expect(response.text == "OK")
        #expect(response.provider == "claude-cli")
        #expect(response.model == "claude-sonnet-5-5")
        #expect(response.inputTokens == 110)
        #expect(response.outputTokens == 110)
        #expect(response.costUSD == 0.047)
    }

    @Test func missingModelUsageFallsBackToRequestedModel() throws {
        let envelope = #"{"type":"result","subtype":"success","is_error":false,"result":"hi"}"#
        let response = try ClaudeCLIProvider.parseEnvelope(Data(envelope.utf8), requestedModel: "haiku")
        #expect(response.model == "haiku")
    }

    @Test func errorEnvelopeIsUnavailable() {
        let envelope =
            #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        #expect(throws: LLMError.unavailable("Not logged in · Please run /login")) {
            try ClaudeCLIProvider.parseEnvelope(Data(envelope.utf8), requestedModel: "haiku")
        }
    }

    @Test func nonSuccessSubtypeIsUnavailable() {
        let envelope = #"{"type":"result","subtype":"error_max_budget_usd","is_error":false}"#
        #expect(throws: LLMError.unavailable("error_max_budget_usd")) {
            try ClaudeCLIProvider.parseEnvelope(Data(envelope.utf8), requestedModel: "haiku")
        }
    }

    @Test func nonJSONOutputIsInvalidResponse() {
        #expect(throws: LLMError.invalidResponse("claude output is not a JSON object")) {
            try ClaudeCLIProvider.parseEnvelope(Data("Error: boom".utf8), requestedModel: "haiku")
        }
    }

    @Test func conversationIsFlattenedButSingleTurnIsVerbatim() {
        #expect(ClaudeCLIProvider.prompt(from: [.user("Hello")]) == "Hello")
        let flattened = ClaudeCLIProvider.prompt(from: [.user("Q1"), .assistant("A1"), .user("Q2")])
        #expect(flattened == "User: Q1\n\nAssistant: A1\n\nUser: Q2")
    }

    @Test func environmentPutsLocalBinFirstOnPath() {
        let env = ClaudeCLIProvider.environment(["PATH": "/usr/bin:/bin", "HOME": "/Users/x"])
        #expect(env["PATH"] == NSHomeDirectory() + "/.local/bin:/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/x")
    }
}

// MARK: - SSE

private func collect(_ lines: String, _ step: (String) -> SSEStep) throws -> String {
    var text = ""
    for line in lines.split(separator: "\n", omittingEmptySubsequences: false) {
        switch step(String(line)) {
        case .text(let delta): text += delta
        case .done: return text
        case .failure(let error): throw error
        case .ignore: continue
        }
    }
    return text
}

@Suite struct SSETests {
    @Test func anthropicStreamConcatenatesTextDeltasUntilMessageStop() throws {
        let fixture = """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-haiku-4-5","usage":{"input_tokens":12,"output_tokens":1}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            event: ping
            data: {"type": "ping"}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

            event: message_stop
            data: {"type":"message_stop"}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"after stop"}}
            """
        #expect(try collect(fixture, AnthropicSSE.step) == "Hello, world")
    }

    @Test func anthropicErrorEventsMapToLLMErrors() {
        let overloaded = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        #expect(AnthropicSSE.step(overloaded) == .failure(.unavailable("Overloaded")))
        let limited = #"data: {"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#
        #expect(AnthropicSSE.step(limited) == .failure(.rateLimited))
    }

    @Test func openAIStreamConcatenatesDeltaContentUntilDone() throws {
        let fixture = """
            data: {"choices":[{"index":0,"delta":{"role":"assistant","content":null}}],"object":"chat.completion.chunk"}

            data: {"choices":[{"index":0,"delta":{"content":"O"}}],"object":"chat.completion.chunk"}

            data: {"choices":[{"index":0,"delta":{"content":"K"}}],"object":"chat.completion.chunk"}

            data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}],"object":"chat.completion.chunk"}

            data: [DONE]

            data: {"choices":[{"index":0,"delta":{"content":"ignored"}}]}
            """
        #expect(try collect(fixture, OpenAISSE.step) == "OK")
    }

    @Test func openAIErrorChunkIsUnavailable() {
        let line = #"data: {"error":{"code":500,"message":"context exceeded","type":"server_error"}}"#
        #expect(OpenAISSE.step(line) == .failure(.unavailable("context exceeded")))
    }
}

// MARK: - Non-streaming HTTP responses

@Suite struct HTTPResponseTests {
    @Test func anthropicMessageIsParsed() throws {
        let body =
            #"{"model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"Hi"},{"type":"text","text":"!"}],"usage":{"input_tokens":4,"output_tokens":2}}"#
        let response = try AnthropicAPIProvider.parseMessage(Data(body.utf8), fallbackModel: "x")
        #expect(response.text == "Hi!")
        #expect(response.model == "claude-haiku-4-5-20251001")
        #expect(response.inputTokens == 4)
        #expect(response.outputTokens == 2)
    }

    @Test func anthropicStatusCodesMapToErrors() throws {
        func status(_ code: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: AnthropicAPIProvider.endpoint, statusCode: code, httpVersion: nil, headerFields: nil)!
        }
        let body = Data(#"{"type":"error","error":{"type":"x","message":"msg"}}"#.utf8)
        try AnthropicAPIProvider.check(status(200), body: body)
        #expect(throws: LLMError.unavailable("invalid API key")) {
            try AnthropicAPIProvider.check(status(401), body: body)
        }
        #expect(throws: LLMError.rateLimited) { try AnthropicAPIProvider.check(status(429), body: body) }
        #expect(throws: LLMError.unavailable("Anthropic API HTTP 529: msg")) {
            try AnthropicAPIProvider.check(status(529), body: body)
        }
        #expect(throws: LLMError.invalidResponse("Anthropic API HTTP 400: msg")) {
            try AnthropicAPIProvider.check(status(400), body: body)
        }
    }

    @Test func openAICompletionIsParsed() throws {
        let body =
            #"{"choices":[{"index":0,"message":{"role":"assistant","content":"OK"}}],"usage":{"prompt_tokens":20,"completion_tokens":1}}"#
        let response = try LlamaServerProvider.parseCompletion(Data(body.utf8), model: "Qwen3-4B-Q4_K_M.gguf")
        #expect(response.text == "OK")
        #expect(response.provider == "local")
        #expect(response.inputTokens == 20)
        #expect(response.outputTokens == 1)
    }
}

// MARK: - Router

private struct StubProvider: LLMProvider {
    let id: String
    var displayName: String { id }
    let contextBudgetTokens = 1000
    let available: Bool
    let failure: LLMError?
    let replies: [String]

    init(_ id: String, available: Bool = true, failure: LLMError? = nil, replies: [String]? = nil) {
        self.id = id
        self.available = available
        self.failure = failure
        self.replies = replies ?? ["from \(id)"]
    }

    func isAvailable() async -> Bool { available }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        if let failure { throw failure }
        let reply =
            request.messages.last?.content.hasSuffix("Return only the JSON object.") == true
            ? replies.last! : replies[0]
        return LLMResponse(text: reply, provider: id, model: "\(id)-model")
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                for word in replies[0].split(separator: " ") { continuation.yield(String(word)) }
                continuation.finish()
            }
        }
    }
}

private let request = LLMRequest(task: .chat, system: "s", messages: [.user("q")])

@Suite struct RouterTests {
    @Test func skipsUnavailableProviderWithoutFailoverEvent() async throws {
        let router = LLMRouter(
            providers: [StubProvider("claude-cli", available: false), StubProvider("anthropic-api")], offlineOnly: false
        )
        let (response, providerID) = try await router.complete(request)
        #expect(providerID == "anthropic-api")
        #expect(response.text == "from anthropic-api")
    }

    @Test func failsOverOnUnavailableAndReportsEvent() async throws {
        let router = LLMRouter(
            providers: [
                StubProvider("claude-cli", failure: .unavailable("timeout")),
                StubProvider("anthropic-api", failure: .rateLimited),
                StubProvider("local"),
            ], offlineOnly: false)
        let (_, providerID) = try await router.complete(request)
        #expect(providerID == "local")

        var events: [LLMRouter.Event] = []
        for await event in router.events {
            events.append(event)
            if events.count == 2 { break }
        }
        #expect(
            events == [
                .failedOver(
                    from: "claude-cli", to: "anthropic-api",
                    reason: LLMError.unavailable("timeout").localizedDescription),
                .failedOver(from: "anthropic-api", to: "local", reason: LLMError.rateLimited.localizedDescription),
            ])
    }

    @Test func invalidResponseDoesNotFailOver() async {
        let router = LLMRouter(
            providers: [StubProvider("claude-cli", failure: .invalidResponse("bad")), StubProvider("local")],
            offlineOnly: false)
        await #expect(throws: LLMError.invalidResponse("bad")) { try await router.complete(request) }
    }

    @Test func allProvidersFailingThrowsLastError() async {
        let router = LLMRouter(
            providers: [
                StubProvider("claude-cli", failure: .unavailable("a")),
                StubProvider("local", failure: .unavailable("b")),
            ], offlineOnly: false)
        await #expect(throws: LLMError.unavailable("b")) { try await router.complete(request) }
    }

    @Test func offlineOnlyRestrictsToLocal() async throws {
        let router = LLMRouter(
            providers: [StubProvider("claude-cli"), StubProvider("anthropic-api"), StubProvider("local")],
            offlineOnly: true)
        #expect(await router.providers(for: .enhance).map(\.id) == ["local"])
        let (_, providerID) = try await router.complete(request)
        #expect(providerID == "local")
    }

    @Test func offlineOnlyWithoutLocalModelIsUnavailable() async {
        let router = LLMRouter(
            providers: [StubProvider("claude-cli"), StubProvider("local", available: false)], offlineOnly: true)
        await #expect(throws: LLMError.unavailable("local model not available (offline only)")) {
            try await router.complete(request)
        }
    }

    @Test func streamFailsOverBeforeFirstDeltaAndNamesProvider() async throws {
        let router = LLMRouter(
            providers: [
                StubProvider("claude-cli", failure: .unavailable("down")),
                StubProvider("local", replies: ["a b c"]),
            ], offlineOnly: false)
        var elements: [LLMRouter.StreamElement] = []
        for try await element in router.stream(request) { elements.append(element) }
        #expect(elements == [.provider(id: "local"), .delta("a"), .delta("b"), .delta("c")])
    }

    @Test func completeJSONRetriesOnceWithReminder() async throws {
        struct Choice: Decodable, Sendable { var template_id: String }
        let router = LLMRouter(
            providers: [StubProvider("local", replies: ["Sure! I'd pick general.", #"{"template_id":"standup"}"#])],
            offlineOnly: false)
        let (value, _, providerID) = try await router.completeJSON(request, as: Choice.self)
        #expect(value.template_id == "standup")
        #expect(providerID == "local")
    }

    @Test func completeJSONThrowsInvalidResponseAfterRetry() async {
        struct Choice: Decodable, Sendable { var template_id: String }
        let router = LLMRouter(providers: [StubProvider("local", replies: ["no json"])], offlineOnly: false)
        await #expect(throws: LLMError.invalidResponse("no decodable JSON object in reply")) {
            try await router.completeJSON(request, as: Choice.self)
        }
    }
}

// MARK: - JSONExtraction

@Suite struct JSONExtractionTests {
    private func object(_ text: String) -> [String: Any]? {
        JSONExtraction.extract(from: text).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    @Test func fencedJSON() {
        let text = "```json\n{\"template_id\": \"standup\"}\n```"
        #expect(object(text)?["template_id"] as? String == "standup")
    }

    @Test func prefixedAndSuffixedProse() {
        let text = "Here is the answer: {\"title\": \"Q3 pricing\"} Let me know if you need more."
        #expect(object(text)?["title"] as? String == "Q3 pricing")
    }

    @Test func nestedBracesAndBracesInsideStrings() {
        let text =
            #"Result: {"suggestions":[{"cluster":"Speaker 1","name":"Priya {PM}","evidence_segment_id":12}],"note":"a \"}\" b"} trailing }"#
        let json = object(text)
        let suggestions = json?["suggestions"] as? [[String: Any]]
        #expect(suggestions?.first?["name"] as? String == "Priya {PM}")
        #expect(json?["note"] as? String == "a \"}\" b")
    }

    @Test func skipsUnparseableBraceGroupBeforeRealObject() {
        let text = "Template {general} fits best: {\"template_id\": \"general\"}"
        #expect(object(text)?["template_id"] as? String == "general")
    }

    @Test func noObjectReturnsNil() {
        #expect(JSONExtraction.extract(from: "no json here") == nil)
        #expect(JSONExtraction.extract(from: "{\"unterminated\": 1") == nil)
    }
}
