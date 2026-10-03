import Foundation

/// Anthropic Messages API with the user's own key.
public struct AnthropicAPIProvider: LLMProvider {
    public let id = "anthropic-api"
    public let displayName = "Claude API"
    public let contextBudgetTokens = 150_000

    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let defaultModels: [LLMTask: String] = [
        .enhance: "claude-haiku-4-5", .chat: "claude-sonnet-5-5", .classify: "claude-haiku-4-5",
    ]

    private let models: [LLMTask: String]
    private let apiKey: @Sendable () -> String?
    private let session: URLSession

    /// - Parameters:
    ///   - models: API model id per task; missing tasks use `defaultModels`.
    ///   - apiKey: read on every request so a key change in Settings applies immediately.
    public init(models: [LLMTask: String], apiKey: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.models = models
        self.apiKey = apiKey
        self.session = session
    }

    public func model(for task: LLMTask) -> String {
        models[task] ?? Self.defaultModels[task] ?? "claude-haiku-4-5"
    }

    private var key: String? { apiKey().flatMap { $0.isEmpty ? nil : $0 } }

    public func isAvailable() async -> Bool { key != nil }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let model = model(for: request.task)
        let urlRequest = try makeRequest(request, model: model, stream: false)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw normalize(error)
        }
        try Self.check(response, body: data)
        return try Self.parseMessage(data, fallbackModel: model)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        let model = model(for: request.task)
        let session = session
        let urlRequest: URLRequest
        do {
            urlRequest = try makeRequest(request, model: model, stream: true)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return .sse(
            {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                if (response as? HTTPURLResponse).map({ !(200..<300).contains($0.statusCode) }) ?? true {
                    var body = Data()
                    for try await byte in bytes { body.append(byte) }
                    try Self.check(response, body: body)
                }
                return bytes
            }, step: AnthropicSSE.step)
    }

    private func makeRequest(_ request: LLMRequest, model: String, stream: Bool) throws -> URLRequest {
        guard let key else { throw LLMError.unavailable("no Anthropic API key") }
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: 300)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": stream,
        ]
        if !request.system.isEmpty { body["system"] = request.system }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// Maps HTTP status to `LLMError`: 401 invalid key, 429 rate limit, 5xx/529 unavailable.
    static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("not an HTTP response") }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw LLMError.unavailable("invalid API key")
        case 429: throw LLMError.rateLimited
        case 500...: throw LLMError.unavailable("Anthropic API HTTP \(http.statusCode): \(errorMessage(body))")
        default: throw LLMError.invalidResponse("Anthropic API HTTP \(http.statusCode): \(errorMessage(body))")
        }
    }

    private static func errorMessage(_ body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return (json?["error"] as? [String: Any])?["message"] as? String
            ?? String(decoding: body.prefix(300), as: UTF8.self)
    }

    /// Parses a non-streaming Messages API response.
    static func parseMessage(_ data: Data, fallbackModel: String) throws -> LLMResponse {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            throw LLMError.invalidResponse("Anthropic response has no content")
        }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        let usage = json["usage"] as? [String: Any]
        return LLMResponse(
            text: text,
            provider: "anthropic-api",
            model: json["model"] as? String ?? fallbackModel,
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int
        )
    }
}
