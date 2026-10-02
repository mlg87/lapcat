import AppKit
import LapCatCore
import SwiftUI

/// Settings → Templates: built-in and custom note templates; custom ones are `*.md` files in the templates folder.
struct TemplatesSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var templates: [Template] = []
    @State private var error: String?

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section {
                Picker("Default template", selection: $settings.templateDefaultID) {
                    Text("Automatic (LapCat picks per meeting)").tag(TemplateLibrary.autoID)
                    ForEach(templates) { Text($0.name).tag($0.id) }
                    if settings.templateDefaultID != TemplateLibrary.autoID,
                       !templates.contains(where: { $0.id == settings.templateDefaultID })
                    {
                        Text("Missing (\(settings.templateDefaultID))").tag(settings.templateDefaultID)
                    }
                }
            }
            Section {
                ForEach(templates) { template in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading) {
                            Text(template.name)
                            if !template.description.isEmpty {
                                Text(template.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(template.isBuiltin ? "Built-in" : "Custom")
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(template.isBuiltin ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.2),
                                        in: Capsule())
                        if let path = template.filePath {
                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Templates")
            } footer: {
                Text("Add a template by saving a Markdown file in the templates folder: `---` frontmatter with "
                    + "`name:` and `description:`, then `##` sections with `<!-- instructions -->`. Then press Rescan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Open templates folder", action: openFolder)
                    Button("Rescan") { Task { await rescan() } }
                }
            }
        }
        .formStyle(.grouped)
        .task { await rescan() }
    }

    private func openFolder() {
        let folder = Paths.standard.templates
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch {
            self.error = "Could not create \(folder.path): \(error.localizedDescription)"
        }
    }

    private func rescan() async {
        do {
            try await TemplateLibrary.sync(store: appState.store, customDirectory: Paths.standard.templates)
            templates = try await appState.store.templates()
            error = nil
        } catch {
            self.error = "Could not load templates: \(error.localizedDescription)"
        }
    }
}
