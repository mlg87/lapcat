import LapCatCore
import LapCatSpeakers
import SwiftUI

/// Settings → Speakers: Zoom/Meet accessibility adapters and their selector overrides.
struct SpeakersSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section {
                Toggle("Read speaker names from Zoom and Google Meet", isOn: $settings.speakersAdaptersEnabled)
                Text("Uses the Accessibility permission. Keep the Meet tab visible for best results; otherwise "
                    + "speakers are labelled Speaker 1, Speaker 2… and you can rename them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Advanced: Zoom selectors (JSON)") {
                SelectorEditor(json: $settings.speakersSelectorsZoom, defaults: .zoomDefault)
            }
            Section("Advanced: Google Meet selectors (JSON)") {
                SelectorEditor(json: $settings.speakersSelectorsMeet, defaults: .meetDefault)
            }
        }
        .formStyle(.grouped)
    }
}

/// Edits one `speakers.selectors.<adapter>` override; saves only JSON that `SpeakerSelectors.validate` accepts.
private struct SelectorEditor: View {
    @Binding var json: String?
    let defaults: SpeakerSelectors
    @State private var draft = ""
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(json == nil ? "Using built-in selectors." : "Using your custom selectors.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 140)
                .onChange(of: draft) {
                    error = nil
                    saved = false
                }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Save", action: save).disabled(draft == currentText)
                Button("Revert") { draft = currentText }.disabled(draft == currentText)
                Button("Restore built-in") {
                    json = nil
                    draft = currentText
                }
                .disabled(json == nil)
                if saved { Text("Saved").font(.caption).foregroundStyle(.green) }
            }
        }
        .onAppear { draft = currentText }
    }

    private var currentText: String {
        json ?? defaults.prettyJSON
    }

    private func save() {
        do {
            let selectors = try SpeakerSelectors.validate(json: draft)
            // Identical to the compiled defaults ⇒ keep following future default updates.
            json = selectors == defaults ? nil : draft
            draft = currentText
            saved = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
