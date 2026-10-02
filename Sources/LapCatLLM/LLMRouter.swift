import Foundation

/// Tries providers in the configured order, failing over on `.unavailable` / `.rateLimited`.
public actor LLMRouter {
    public enum Event: Sendable, Equatable {
        case failedOver(from: String, to: String, reason: String)
    }

    /// Elements of `stream(_:)`: which provider answered, then its text deltas.
    public enum StreamElement: Sendable, Equatable {
        case provider(id: String)
        case delta(String)
    }

    public static let localProviderID = "local"

    private let allProviders: [any LLMProvider]
    private let offlineOnly: Bool
    public nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    /// - Parameters:
    ///   - providers: in preference order (the app passes them ordered by `llm.providerOrder`).
    ///   - offlineOnly: restricts routing to the `local` provider.
    public init(providers: [any LLMProvider], offlineOnly: Bool) {
        allProviders = providers
        self.offlineOnly = offlineOnly
        (events, eventSink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(64))
    }

    deinit { eventSink.finish() }

    /// Available providers for `task`, in order; only `local` when offline-only.
    public func providers(for task: LLMTask) async -> [any LLMProvider] {
        var available: [any LLMProvider] = []
        for provider in allProviders where !offlineOnly || provider.id == Self.localProviderID {
            if await provider.isAvailable() { available.append(provider) }
        }
        return available
    }

    /// The provider a request for `task` would try first, if any.
    public func head(for task: LLMTask) async -> (any LLMProvider)? {
        await providers(for: task).first
    }

    /// Completes with the first provider that succeeds. Returns the response and the provider id.
    public func complete(_ request: LLMRequest) async throws -> (response: LLMResponse, providerID: String) {
        let candidates = try await candidates(for: request.task)
        var lastError = LLMError.unavailable("no LLM provider available")
        for (index, provider) in candidates.enumerated() {
            do {
                return (try await provider.complete(request), provider.id)
            } catch {
                lastError = normalize(error)
                guard lastError.allowsFailover, index + 1 < candidates.count else { throw lastError }
                failedOver(from: provider, to: candidates[index + 1], reason: lastError)
            }
        }
        throw lastError
    }

    /// Streams from the first provider that starts successfully. Failover happens only before the
    /// first delta; an error after text has been delivered ends the stream with that error.
    public nonisolated func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let candidates = try await self.candidates(for: request.task)
                    var lastError = LLMError.unavailable("no LLM provider available")
                    for (index, provider) in candidates.enumerated() {
                        var started = false
                        do {
                            for try await delta in provider.stream(request) {
                                if !started {
                                    started = true
                                    continuation.yield(.provider(id: provider.id))
                                }
                                continuation.yield(.delta(delta))
                            }
                            if !started { continuation.yield(.provider(id: provider.id)) }
                            continuation.finish()
                            return
                        } catch {
                            lastError = normalize(error)
                            guard !started, lastError.allowsFailover, index + 1 < candidates.count else { throw lastError }
                            await self.failedOver(from: provider, to: candidates[index + 1], reason: lastError)
                        }
                    }
                    throw lastError
                } catch {
                    continuation.finish(throwing: normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Completes an `expectJSON` request and decodes the first JSON object in the reply. On a decode
    /// failure retries once with "Return only the JSON object." appended to the last user message.
    public func completeJSON<T: Decodable & Sendable>(
        _ request: LLMRequest, as type: T.Type
    ) async throws -> (value: T, response: LLMResponse, providerID: String) {
        var request = request
        request.expectJSON = true
        let first = try await complete(request)
        if let value = JSONExtraction.decode(type, from: first.response.text) {
            return (value, first.response, first.providerID)
        }
        if let index = request.messages.lastIndex(where: { $0.role == .user }) {
            request.messages[index].content += "\n\nReturn only the JSON object."
        }
        let retry = try await complete(request)
        guard let value = JSONExtraction.decode(type, from: retry.response.text) else {
            throw LLMError.invalidResponse("no decodable JSON object in reply")
        }
        return (value, retry.response, retry.providerID)
    }

    private func candidates(for task: LLMTask) async throws -> [any LLMProvider] {
        let candidates = await providers(for: task)
        if candidates.isEmpty {
            throw offlineOnly ? LLMError.unavailable("local model not available (offline only)") : LLMError.unavailable("no LLM provider available")
        }
        return candidates
    }

    private func failedOver(from: any LLMProvider, to: any LLMProvider, reason: LLMError) {
        eventSink.yield(.failedOver(from: from.id, to: to.id, reason: reason.localizedDescription))
    }
}
