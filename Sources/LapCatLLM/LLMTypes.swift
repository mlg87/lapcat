import Foundation

public enum LLMTask: String, Sendable, CaseIterable {
    case enhance, chat, classify
}

public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func user(_ content: String) -> LLMMessage { LLMMessage(role: .user, content: content) }
    public static func assistant(_ content: String) -> LLMMessage { LLMMessage(role: .assistant, content: content) }
}

public struct LLMRequest: Sendable {
    public var task: LLMTask
    public var system: String
    public var messages: [LLMMessage]
    public var maxTokens: Int
    public var expectJSON: Bool

    public init(task: LLMTask, system: String, messages: [LLMMessage], maxTokens: Int = 4096, expectJSON: Bool = false) {
        self.task = task
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.expectJSON = expectJSON
    }
}

public struct LLMResponse: Sendable {
    public var text: String
    public var provider: String
    public var model: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?

    public init(text: String, provider: String, model: String, inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil) {
        self.text = text
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }
}

public enum LLMError: Error, Equatable, Sendable {
    case unavailable(String)
    case rateLimited
    case invalidResponse(String)
    case cancelled
    case offlineOnly
    case budgetExceeded

    /// Errors after which the router tries the next provider.
    var allowsFailover: Bool {
        switch self {
        case .unavailable, .rateLimited: true
        case .invalidResponse, .cancelled, .offlineOnly, .budgetExceeded: false
        }
    }
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "LLM provider unavailable: \(reason)"
        case .rateLimited: "LLM provider rate limit reached"
        case .invalidResponse(let detail): "Invalid LLM response: \(detail)"
        case .cancelled: "LLM request cancelled"
        case .offlineOnly: "Offline-only mode allows only the local model"
        case .budgetExceeded: "LLM budget exceeded"
        }
    }
}

public protocol LLMProvider: Sendable {
    /// "claude-cli" | "anthropic-api" | "local"
    var id: String { get }
    /// "Claude via CLI" | "Claude API" | "Local"
    var displayName: String { get }
    /// Prompt budget the enhancer plans against (150_000 | 150_000 | 24_000).
    var contextBudgetTokens: Int { get }
    func isAvailable() async -> Bool
    func complete(_ request: LLMRequest) async throws -> LLMResponse
    /// Text deltas. Providers without streaming yield the whole text as one chunk.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

/// Maps a thrown error to `LLMError`, turning task cancellation and URL failures into their LLM equivalents.
func normalize(_ error: any Error) -> LLMError {
    if let error = error as? LLMError { return error }
    if error is CancellationError { return .cancelled }
    if let error = error as? URLError {
        return error.code == .cancelled ? .cancelled : .unavailable(error.localizedDescription)
    }
    return .unavailable(error.localizedDescription)
}

extension AsyncThrowingStream where Element == String, Failure == Error {
    /// A stream that yields the full completion text as a single chunk.
    static func single(_ produce: @escaping @Sendable () async throws -> String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await produce())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
