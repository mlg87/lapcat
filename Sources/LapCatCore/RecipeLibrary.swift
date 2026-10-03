import Foundation
import GRDB

public enum RecipeError: Error, Equatable, Sendable {
    /// The slash command is empty or contains whitespace after normalisation.
    case invalidSlashCommand(String)
    /// Another recipe already uses this slash command; carries that recipe's name.
    case duplicateSlashCommand(command: String, usedBy: String)
    case emptyName
    case emptyPrompt
    /// Built-in recipes are reseeded on launch and cannot be edited.
    case builtinNotEditable(String)
}

extension RecipeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSlashCommand(let command): "“\(command)” is not a valid slash command"
        case .duplicateSlashCommand(let command, let usedBy): "\(command) is already used by “\(usedBy)”"
        case .emptyName: "A recipe needs a name"
        case .emptyPrompt: "A recipe needs a prompt"
        case .builtinNotEditable(let name): "“\(name)” is built in and cannot be edited"
        }
    }
}

/// Built-in chat recipes shipped as `Recipes.json` in the LapCatCore resource bundle.
public enum RecipeLibrary {
    private struct Entry: Decodable {
        var id: String
        var name: String
        var slash_command: String
        var prompt: String
    }

    /// The bundled built-in recipes.
    public static func builtins() throws -> [Recipe] {
        let data = try Data(contentsOf: try resourceURL("Recipes", ext: "json"))
        return try JSONDecoder().decode([Entry].self, from: data).map {
            Recipe(id: $0.id, name: $0.name, slashCommand: $0.slash_command, prompt: $0.prompt, isBuiltin: true)
        }
    }

    /// Upserts every built-in recipe (`is_builtin = 1`) and deletes built-in rows no longer shipped.
    /// Idempotent; called on every launch.
    public static func seed(store: Store) async throws {
        try await store.replaceBuiltinRecipes(try builtins())
    }

    /// Finds a resource of the LapCatCore bundle. Inside `LapCat.app` the bundle lives in
    /// `Contents/Resources/`, which SwiftPM's generated `Bundle.module` accessor does not search
    /// (it checks the app root and the build directory), so the bundled location is tried first.
    static func resourceURL(_ name: String, ext: String) throws -> URL {
        let bundleName = "LapCat_LapCatCore.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap {
            $0?.appendingPathComponent(bundleName)
        }
        for candidate in candidates {
            if let url = Bundle(url: candidate)?.url(forResource: name, withExtension: ext) { return url }
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) { return url }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(bundleName)/\(name).\(ext)"])
    }
}

extension Store {
    /// Normalised form of a user-typed slash command: trimmed, lowercased, with a leading `/`.
    /// Nil when nothing remains after the slash or it contains whitespace.
    public static func normalizedSlashCommand(_ raw: String) -> String? {
        var command = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !command.hasPrefix("/") { command = "/" + command }
        guard command.count > 1, !command.contains(where: \.isWhitespace) else { return nil }
        return command
    }

    /// Creates or updates a custom recipe (`is_builtin = 0`). The slash command is normalised and must
    /// not be used by any other recipe, built-in or custom. Returns the saved recipe.
    @discardableResult
    public func saveCustomRecipe(
        id: String = "custom:" + UUID().uuidString, name: String, slashCommand: String, prompt: String
    ) async throws -> Recipe {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RecipeError.emptyName }
        guard !prompt.isEmpty else { throw RecipeError.emptyPrompt }
        guard let command = Self.normalizedSlashCommand(slashCommand) else {
            throw RecipeError.invalidSlashCommand(slashCommand)
        }
        let recipe = Recipe(id: id, name: name, slashCommand: command, prompt: prompt, isBuiltin: false)
        try await pool.write { db in
            if let existing = try Recipe.fetchOne(db, key: id), existing.isBuiltin {
                throw RecipeError.builtinNotEditable(existing.name)
            }
            if let clash =
                try Recipe
                .filter(Column("slash_command") == command && Column("id") != id)
                .fetchOne(db)
            {
                throw RecipeError.duplicateSlashCommand(command: command, usedBy: clash.name)
            }
            try recipe.save(db)
        }
        return recipe
    }

    /// Upserts `builtins` and removes built-in rows whose id is not among them.
    func replaceBuiltinRecipes(_ builtins: [Recipe]) async throws {
        try await pool.write { db in
            let ids = builtins.map(\.id)
            try Recipe.filter(Column("is_builtin") == true && !ids.contains(Column("id"))).deleteAll(db)
            for recipe in builtins { try recipe.insert(db, onConflict: .replace) }
        }
    }
}
