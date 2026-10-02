import AppKit
import LapCatCore
import SwiftUI

/// Settings → Export: the folder every finished meeting is auto-exported to as Markdown.
struct ExportSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section {
                LabeledContent("Folder", value: settings.exportAutoExportFolder ?? "Off")
                if let path = settings.exportAutoExportFolder, !FileManager.default.fileExists(atPath: path) {
                    Text("This folder does not exist right now; exports are skipped until it does.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Choose folder…", action: choose)
                    Button("Show in Finder") {
                        if let path = settings.exportAutoExportFolder { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    .disabled(settings.exportAutoExportFolder == nil)
                    Button("Turn off") { settings.exportAutoExportFolder = nil }
                        .disabled(settings.exportAutoExportFolder == nil)
                }
            } header: {
                Text("Auto-export")
            } footer: {
                Text("After a meeting’s final notes are ready, LapCat writes “YYYY-MM-DD Title.md” (notes, your notes "
                    + "and transcript) here, replacing the previous export of the same meeting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if let path = appState.settings.exportAutoExportFolder { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.settings.exportAutoExportFolder = url.path
    }
}
