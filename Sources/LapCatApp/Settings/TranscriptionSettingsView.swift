import LapCatCore
import LapCatSpeech
import SwiftUI

/// Settings → Transcription: engine, whisper models (with downloads), live hypothesis.
struct TranscriptionSettingsView: View {
    @Environment(AppState.self) private var appState

    private static let whisperModels = ModelCatalog.all.filter { $0.kind == .whisper }

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section {
                Picker("Engine", selection: $settings.sttEngine) {
                    Text("Automatic").tag(SpeechConfig.EngineChoice.auto.rawValue)
                    Text("Whisper").tag(SpeechConfig.EngineChoice.whisper.rawValue)
                    Text("Parakeet").tag(SpeechConfig.EngineChoice.parakeet.rawValue)
                }
                #if arch(x86_64)
                    Text("Parakeet is unavailable on Intel Macs; this Mac always transcribes with Whisper.")
                        .font(.caption).foregroundStyle(.secondary)
                #else
                    Text("Automatic uses Parakeet (downloaded by LapCat on first use).")
                        .font(.caption).foregroundStyle(.secondary)
                #endif
                Toggle("Show in-progress text while someone is speaking", isOn: $settings.sttLiveHypothesis)
                Text("Re-transcribes the current utterance every 2 s. Costs CPU; off by default on Intel.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Speech recognition")
            }

            Section("Whisper models") {
                modelPicker("Live transcript", selection: $settings.sttWhisperLiveModel)
                modelPicker("Final transcript (after the meeting)", selection: $settings.sttWhisperFinalModel)
            }

            Section {
                ForEach(Self.whisperModels) { ModelDownloadRow(entry: $0) }
                if settings.llmOfflineOnly { OfflineDownloadNote() }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Stored in \(Paths.standard.models.path)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { ModelDownloads.shared.refresh() }
    }

    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Self.whisperModels) { entry in
                Text(
                    entry.displayName
                        + (ModelDownloads.shared.state(of: entry.id) == .available ? "" : " — not downloaded")
                )
                .tag(entry.id)
            }
            if !Self.whisperModels.contains(where: { $0.id == selection.wrappedValue }) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
    }
}
