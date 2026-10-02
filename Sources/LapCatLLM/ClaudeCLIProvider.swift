import Foundation

/// Runs the user's logged-in `claude` CLI in print mode and parses its single JSON result envelope.
public struct ClaudeCLIProvider: LLMProvider {
    public let id = "claude-cli"
    public let displayName = "Claude via CLI"
    public let contextBudgetTokens = 150_000

    /// Interactive tasks (chat, classify) give up after 3 minutes. Enhance runs in the background
    /// after a meeting, and one map or reduce call over a long meeting can take Sonnet longer than
    /// that (a 2-hour soak meeting timed out at 180 s).
    public static func timeout(for task: LLMTask) -> TimeInterval {
        task == .enhance ? 600 : 180
    }
    public static let defaultModels: [LLMTask: String] = [.enhance: "sonnet", .chat: "sonnet", .classify: "haiku"]

    private let models: [LLMTask: String]
    private let claudePath: String?

    /// - Parameters:
    ///   - models: CLI model alias per task; missing tasks use `defaultModels`.
    ///   - claudePath: explicit binary path; nil searches `~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin`.
    public init(models: [LLMTask: String], claudePath: String?) {
        self.models = models
        self.claudePath = claudePath.flatMap { $0.isEmpty ? nil : $0 }
    }

    static var localBin: String { NSHomeDirectory() + "/.local/bin" }

    /// The `claude` binary to run, or nil when none exists.
    public var binaryURL: URL? {
        let fm = FileManager.default
        if let claudePath {
            let path = (claudePath as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return [Self.localBin + "/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
            .first(where: fm.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    public func model(for task: LLMTask) -> String {
        models[task] ?? Self.defaultModels[task] ?? "sonnet"
    }

    public func isAvailable() async -> Bool { binaryURL != nil }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await completeWithEnvelope(request).response
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        .single { try await complete(request).text }
    }

    /// Like `complete`, also returning the raw stdout envelope (for `lapcat-dev llm-probe`).
    public func completeWithEnvelope(_ request: LLMRequest) async throws -> (envelope: String, response: LLMResponse) {
        guard let binary = binaryURL else { throw LLMError.unavailable("claude CLI not found") }
        let model = model(for: request.task)
        let arguments = [
            "-p", "--output-format", "json", "--model", model, "--tools", "", "--no-session-persistence",
            "--system-prompt", request.system, "--max-budget-usd", "2.00",
        ]
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                executable: binary,
                arguments: arguments,
                environment: Self.environment(),
                stdin: Data(Self.prompt(from: request.messages).utf8),
                timeout: Self.timeout(for: request.task)
            )
        } catch {
            throw LLMError.unavailable("could not launch claude: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        if output.timedOut { throw LLMError.unavailable("timeout") }
        let envelope = String(decoding: output.stdout, as: UTF8.self)
        do {
            return (envelope, try Self.parseEnvelope(output.stdout, requestedModel: model))
        } catch let error as LLMError where output.status != 0 {
            // Non-JSON stdout from a failed run: the reason is on stderr.
            let reason = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if case .invalidResponse = error {
                throw LLMError.unavailable("claude exited \(output.status): \(reason.isEmpty ? envelope : reason)")
            }
            throw error
        }
    }

    /// The user's environment with `~/.local/bin` first on `PATH`. Credentials are inherited, never set.
    static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let path = env["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = localBin + ":" + path
        return env
    }

    /// A single user turn is passed verbatim; conversations are flattened into labelled turns.
    static func prompt(from messages: [LLMMessage]) -> String {
        if messages.count == 1, messages[0].role == .user { return messages[0].content }
        return messages.map { message in
            (message.role == .user ? "User: " : "Assistant: ") + message.content
        }.joined(separator: "\n\n")
    }

    /// Parses the `--output-format json` result envelope.
    static func parseEnvelope(_ data: Data, requestedModel: String) throws -> LLMResponse {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LLMError.invalidResponse("claude output is not a JSON object")
        }
        let result = json["result"] as? String
        if json["is_error"] as? Bool == true || json["subtype"] as? String != "success" {
            let reason = result ?? (json["subtype"] as? String) ?? "unknown error"
            throw LLMError.unavailable(reason)
        }
        guard let result else { throw LLMError.invalidResponse("envelope has no result") }

        // The model that produced the answer is the one with the most output tokens.
        let usage = json["modelUsage"] as? [String: [String: Any]] ?? [:]
        let model = usage.max { lhs, rhs in
            (lhs.value["outputTokens"] as? Int ?? 0, rhs.key) < (rhs.value["outputTokens"] as? Int ?? 0, lhs.key)
        }?.key ?? requestedModel

        let tokens = json["usage"] as? [String: Any]
        let inputTokens = tokens.map { tokens in
            ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + (tokens[$1] as? Int ?? 0) }
        }
        return LLMResponse(
            text: result,
            provider: "claude-cli",
            model: model,
            inputTokens: inputTokens,
            outputTokens: tokens?["output_tokens"] as? Int,
            costUSD: json["total_cost_usd"] as? Double
        )
    }
}
