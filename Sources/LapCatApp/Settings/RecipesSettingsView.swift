import LapCatCore
import SwiftUI

/// Settings → Recipes: built-in chat recipes (read-only) and custom ones (add / edit / delete).
struct RecipesSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var recipes: [Recipe] = []
    @State private var editor: Draft?
    @State private var loadError: String?

    /// The recipe being edited; `id == nil` for a new one.
    struct Draft: Equatable {
        var id: String?
        var name = ""
        var slashCommand = ""
        var prompt = ""
        var error: String?
    }

    var body: some View {
        Form {
            Section("Built-in") {
                ForEach(recipes.filter(\.isBuiltin)) { RecipeRow(recipe: $0) }
            }
            Section("Custom") {
                ForEach(recipes.filter { !$0.isBuiltin }) { recipe in
                    HStack(alignment: .firstTextBaseline) {
                        RecipeRow(recipe: recipe)
                        Spacer()
                        Button("Edit") {
                            editor = Draft(
                                id: recipe.id, name: recipe.name, slashCommand: recipe.slashCommand,
                                prompt: recipe.prompt)
                        }
                        Button("Delete", role: .destructive) { Task { await delete(recipe) } }
                    }
                }
                if editor == nil {
                    Button("Add recipe…") { editor = Draft() }
                }
                if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
            }
            if editor != nil {
                Section(editor?.id == nil ? "New recipe" : "Edit recipe") { editorFields }
            }
        }
        .formStyle(.grouped)
        .task { await load(seed: true) }
    }

    @ViewBuilder
    private var editorFields: some View {
        let draft = Binding {
            editor ?? Draft()
        } set: {
            editor = $0
        }
        TextField("Name", text: draft.name)
        TextField("Slash command", text: draft.slashCommand, prompt: Text("/summary"))
        VStack(alignment: .leading) {
            Text("Prompt")
            TextEditor(text: draft.prompt)
                .font(.body)
                .frame(height: 80)
        }
        if let error = editor?.error {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        }
        HStack {
            Button("Cancel") { editor = nil }
            Button("Save") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func save() async {
        guard var draft = editor else { return }
        do {
            if let id = draft.id {
                try await appState.store.saveCustomRecipe(
                    id: id, name: draft.name, slashCommand: draft.slashCommand, prompt: draft.prompt)
            } else {
                try await appState.store.saveCustomRecipe(
                    name: draft.name, slashCommand: draft.slashCommand, prompt: draft.prompt)
            }
            editor = nil
            await load(seed: false)
        } catch {
            draft.error = error.localizedDescription
            editor = draft
        }
    }

    private func delete(_ recipe: Recipe) async {
        do {
            try await appState.store.deleteCustomRecipe(id: recipe.id)
            if editor?.id == recipe.id { editor = nil }
            await load(seed: false)
        } catch {
            loadError = "Could not delete “\(recipe.name)”: \(error.localizedDescription)"
        }
    }

    /// `seed` reseeds built-ins first (idempotent) so the list is complete even before the launch seed ran.
    private func load(seed: Bool) async {
        do {
            if seed { try await RecipeLibrary.seed(store: appState.store) }
            recipes = try await appState.store.recipes()
            loadError = nil
        } catch {
            loadError = "Could not load recipes: \(error.localizedDescription)"
        }
    }
}

private struct RecipeRow: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(recipe.slashCommand).font(.system(.body, design: .monospaced))
                Text(recipe.name)
            }
            Text(recipe.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}
