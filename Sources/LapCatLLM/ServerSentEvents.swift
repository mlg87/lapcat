import Foundation

/// What one SSE line contributes to a streamed completion.
enum SSEStep: Equatable, Sendable {
    case text(String)
    case done
    case failure(LLMError)
    case ignore
}

/// The JSON payload of a `data:` line, or nil for comments, `event:` lines and blanks.
private func payload(of line: Substring) -> Substring? {
    guard line.hasPrefix("data:") else { return nil }
    return line.dropFirst(5).drop(while: { $0 == " " })
}

private func object(_ data: Substring) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any]
}

/// Anthropic Messages API stream: `content_block_delta` text deltas until `message_stop`.
enum AnthropicSSE {
    static func step(_ line: some StringProtocol) -> SSEStep {
        guard let data = payload(of: Substring(line)), let json = object(data) else { return .ignore }
        switch json["type"] as? String {
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String
            else { return .ignore }
            return .text(text)
        case "message_stop":
            return .done
        case "error":
            let error = json["error"] as? [String: Any]
            let kind = error?["type"] as? String ?? "error"
            let message = error?["message"] as? String ?? kind
            return .failure(kind == "rate_limit_error" ? .rateLimited : .unavailable(message))
        default:
            return .ignore
        }
    }
}

/// OpenAI-compatible chat completions stream (llama-server): `choices[0].delta.content` until `[DONE]`.
enum OpenAISSE {
    static func step(_ line: some StringProtocol) -> SSEStep {
        guard let data = payload(of: Substring(line)) else { return .ignore }
        if data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return .done }
        guard let json = object(data) else { return .ignore }
        if let error = json["error"] as? [String: Any] {
            return .failure(.unavailable(error["message"] as? String ?? "server error"))
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
            let delta = choice["delta"] as? [String: Any],
            let text = delta["content"] as? String, !text.isEmpty
        else { return .ignore }
        return .text(text)
    }
}

extension AsyncThrowingStream where Element == String, Failure == Error {
    /// Streams text deltas parsed from an SSE response body.
    static func sse(
        _ open: @escaping @Sendable () async throws -> URLSession.AsyncBytes,
        step: @escaping @Sendable (String) -> SSEStep
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in try await open().lines {
                        switch step(line) {
                        case .text(let text): continuation.yield(text)
                        case .done:
                            continuation.finish()
                            return
                        case .failure(let error): throw error
                        case .ignore: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
