import Foundation
import LapCatCore
import LapCatLLM
import Observation

/// Builds the LLM router from `AppSettings` and keeps it current as settings change.
///
/// The local `LlamaServerProvider` is kept per GGUF file so a running `llama-server` is reused
/// across requests; the router is rebuilt whenever the provider configuration changes.
@Observable @MainActor
final class LLMServices {
    /// Latest failover reported by the router, for a UI banner.
    private(set) var lastFailover: LLMRouter.Event?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var cached: (signature: Signature, router: LLMRouter)?
    @ObservationIgnored private var local: LlamaServerProvider?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    private struct Signature: Equatable {
        var order: [String]
        var models: [String: [String: String]]
        var claudePath: String?
        var offlineOnly: Bool
    }

    var router: LLMRouter {
        let signature = Signature(
            order: settings.llmProviderOrder, models: settings.llmModels,
            claudePath: settings.llmClaudePath, offlineOnly: settings.llmOfflineOnly)
        if let cached, cached.signature == signature { return cached.router }
        let router = LLMRouter(providers: signature.order.compactMap(provider(id:)), offlineOnly: signature.offlineOnly)
        cached = (signature, router)
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in router.events {
                self?.lastFailover = event
            }
        }
        return router
    }

    /// A provider built from current settings; used by the router and by Settings → AI "Test".
    func provider(id: String) -> (any LLMProvider)? {
        switch id {
        case "claude-cli":
            return ClaudeCLIProvider(models: models(for: id), claudePath: settings.llmClaudePath)
        case "anthropic-api":
            return AnthropicAPIProvider(models: models(for: id), apiKey: { Keychain.apiKey() })
        case "local":
            return localProvider()
        default:
            return nil
        }
    }

    /// The GGUF the local provider runs (the `enhance` model; one server serves every task).
    var localModelURL: URL {
        Paths.standard.models.appendingPathComponent(
            settings.llmModel(provider: "local", task: "enhance") ?? "Qwen3-4B-Q4_K_M.gguf")
    }

    func shutdown() {
        guard let local else { return }
        Task { await local.shutdown() }
    }

    private func localProvider() -> LlamaServerProvider {
        let url = localModelURL
        if let local, local.ggufURL == url { return local }
        if let local { Task { await local.shutdown() } }
        let provider = LlamaServerProvider(ggufURL: url, helpersDirectory: nil)
        local = provider
        return provider
    }

    private func models(for provider: String) -> [LLMTask: String] {
        var result: [LLMTask: String] = [:]
        for task in [LLMTask.enhance, .chat, .classify] {
            if let model = settings.llmModel(provider: provider, task: task.rawValue) { result[task] = model }
        }
        return result
    }
}
