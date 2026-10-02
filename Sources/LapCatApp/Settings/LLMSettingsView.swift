import LapCatCore
import LapCatLLM
import LapCatSpeech
import SwiftUI

/// Settings → AI: provider order, per-task models, API key, `claude` path, offline mode, tests.
struct LLMSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKey = ""
    @State private var apiKeyStored = Keychain.apiKey() != nil
    @State private var apiKeyError: String?
    @State private var testResults: [String: TestResult] = [:]

    private static let names = ["claude-cli": "Claude via CLI", "anthropic-api": "Claude API", "local": "Local"]
    private static let tasks = ["enhance", "chat", "classify"]

    enum TestResult: Equatable {
        case running
        case passed(String)
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section {
                List {
                    ForEach(settings.llmProviderOrder, id: \.self) { id in
                        providerRow(id)
                    }
                    .onMove { settings.llmProviderOrder.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 110)
                Toggle("Offline only (local model; no network)", isOn: $settings.llmOfflineOnly)
            } header: {
                Text("Providers — drag to reorder; LapCat falls back down the list")
            }

            Section("Models") {
                Grid(alignment: .leading) {
                    GridRow {
                        Text("")
                        ForEach(Self.tasks, id: \.self) { Text($0.capitalized).font(.caption.bold()) }
                    }
                    ForEach(AppSettings.Default.llmProviderOrder, id: \.self) { provider in
                        GridRow {
                            Text(Self.names[provider] ?? provider)
                            ForEach(Self.tasks, id: \.self) { task in
                                TextField(task, text: Binding(
                                    get: { settings.llmModel(provider: provider, task: task) ?? "" },
                                    set: { settings.setLLMModel($0, provider: provider, task: task) }
                                ))
                            }
                        }
                    }
                }
            }

            Section("Claude API key") {
                HStack {
                    SecureField(apiKeyStored ? "Stored in Keychain — type to replace" : "sk-ant-…", text: $apiKey)
                        .onSubmit(saveAPIKey)
                    Button("Save", action: saveAPIKey).disabled(apiKey.isEmpty)
                    Button("Remove") {
                        Keychain.deleteAPIKey()
                        apiKeyStored = false
                    }
                    .disabled(!apiKeyStored)
                }
                if let apiKeyError { Text(apiKeyError).font(.caption).foregroundStyle(.red) }
            }

            Section("Claude CLI") {
                TextField("Path to claude (blank = ~/.local/bin, /usr/local/bin, /opt/homebrew/bin)", text: Binding(
                    get: { settings.llmClaudePath ?? "" },
                    set: { settings.llmClaudePath = $0.isEmpty ? nil : $0 }
                ))
            }

            Section("Local model") {
                let file = appState.llm.localModelURL
                if let entry = ModelCatalog.entry(id: file.lastPathComponent) {
                    ModelDownloadRow(entry: entry)
                    if settings.llmOfflineOnly { OfflineDownloadNote() }
                } else {
                    LabeledContent("File", value: file.path)
                    if ModelDownloads.shared.state(of: file.lastPathComponent) != .available {
                        Text("Not in LapCat’s catalog — place the file at this path yourself.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if ModelDownloads.shared.state(of: file.lastPathComponent) != .available {
                    Text("Not downloaded yet — the Local provider is unavailable until it is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { ModelDownloads.shared.refresh() }
    }

    @ViewBuilder
    private func providerRow(_ id: String) -> some View {
        HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Text(Self.names[id] ?? id)
            Spacer()
            switch testResults[id] {
            case .running?: ProgressView().controlSize(.small)
            case .passed(let detail)?: Label(detail, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
            case .failed(let detail)?: Label(detail, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(1)
            case nil: EmptyView()
            }
            Button("Test") { test(id) }.disabled(testResults[id] == .running)
        }
    }

    private func saveAPIKey() {
        guard !apiKey.isEmpty else { return }
        do {
            try Keychain.setAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            apiKey = ""
            apiKeyStored = true
            apiKeyError = nil
        } catch {
            apiKeyError = "Could not save to Keychain: \(error)"
        }
    }

    private func test(_ id: String) {
        guard let provider = appState.llm.provider(id: id) else { return }
        testResults[id] = .running
        Task {
            guard await provider.isAvailable() else {
                testResults[id] = .failed("Not available")
                return
            }
            let request = LLMRequest(
                task: .classify, system: "You are a connectivity test.",
                messages: [.init(role: .user, content: "Reply with exactly: OK")], maxTokens: 16)
            do {
                let response = try await provider.complete(request)
                testResults[id] = .passed("\(response.model): \(response.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch {
                testResults[id] = .failed(error.localizedDescription)
            }
        }
    }
}
