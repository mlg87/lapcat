import LapCatCore
import SwiftUI

/// Settings tabs as a sidebar: nine toolbar tabs do not fit the 680 pt window (they collapse
/// into the toolbar overflow menu).
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case audio = "Audio"
        case transcription = "Transcription"
        case ai = "AI"
        case speakers = "Speakers"
        case detection = "Detection"
        case templates = "Templates"
        case recipes = "Recipes"
        case export = "Export"

        var id: Self { self }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .audio: "waveform"
            case .transcription: "text.bubble"
            case .ai: "sparkles"
            case .speakers: "person.2"
            case .detection: "bell.badge"
            case .templates: "doc.text"
            case .recipes: "list.bullet.rectangle"
            case .export: "square.and.arrow.up"
            }
        }
    }

    @State private var selection: Tab = .general

    var body: some View {
        HStack(spacing: 0) {
            List(Tab.allCases, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
            }
            .listStyle(.sidebar)
            .frame(width: 170)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettingsView()
        case .audio: AudioSettingsView()
        case .transcription: TranscriptionSettingsView()
        case .ai: LLMSettingsView()
        case .speakers: SpeakersSettingsView()
        case .detection: DetectionSettingsView()
        case .templates: TemplatesSettingsView()
        case .recipes: RecipesSettingsView()
        case .export: ExportSettingsView()
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("You") {
                TextField("Display name", text: $settings.userDisplayName)
                Text("Used for your own (“Me”) lines in transcripts and notes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Global shortcuts") {
                ForEach(HotKeyAction.allCases) { action in
                    KeyRecorderView(action: action)
                }
            }
            Section("Consent") {
                Toggle("Remind me to tell participants when a recording starts", isOn: $settings.consentReminderEnabled)
                VStack(alignment: .leading) {
                    Text("Disclosure message (copied from the reminder banner)")
                    TextEditor(text: $settings.consentCannedMessage)
                        .font(.body)
                        .frame(height: 60)
                }
                Button("Restore default message") {
                    settings.consentCannedMessage = AppSettings.Default.consentCannedMessage
                }
                .disabled(settings.consentCannedMessage == AppSettings.Default.consentCannedMessage)
            }
            Section("Permissions") {
                Button("Show permissions checklist…") { appState.showPermissions() }
            }
        }
        .formStyle(.grouped)
    }
}
