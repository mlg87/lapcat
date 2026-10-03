import Foundation
import Testing
@testable import LapCatCore

struct RecipeTests {
    @Test func seedingTwiceKeepsOneRowPerBuiltinAndRemovesRetiredBuiltins() async throws {
        let (store, _) = try makeTempStore()
        try await store.upsertRecipe(
            Recipe(id: "retired", name: "Old", slashCommand: "/old", prompt: "x", isBuiltin: true))
        try await RecipeLibrary.seed(store: store)
        try await RecipeLibrary.seed(store: store)
        let recipes = try await store.recipes()
        #expect(Set(recipes.map(\.slashCommand)) == ["/follow-up", "/actions", "/decisions", "/questions", "/mine"])
        #expect(recipes.allSatisfy { $0.isBuiltin })
        let followUp = try #require(recipes.first { $0.id == "follow-up-email" })
        #expect(followUp.prompt.hasPrefix("Draft a follow-up email to the attendees"))
    }

    @Test func seedingKeepsCustomRecipes() async throws {
        let (store, _) = try makeTempStore()
        try await store.saveCustomRecipe(name: "Risks", slashCommand: "risks", prompt: "List risks.")
        try await RecipeLibrary.seed(store: store)
        let custom = try await store.recipes().filter { !$0.isBuiltin }
        #expect(custom.map(\.slashCommand) == ["/risks"])
    }

    @Test func customRecipeWithTakenSlashCommandIsRejected() async throws {
        let (store, _) = try makeTempStore()
        try await RecipeLibrary.seed(store: store)
        await #expect(throws: RecipeError.duplicateSlashCommand(command: "/actions", usedBy: "Action items")) {
            try await store.saveCustomRecipe(name: "Mine", slashCommand: " /Actions ", prompt: "p")
        }
        let first = try await store.saveCustomRecipe(name: "Risks", slashCommand: "/risks", prompt: "p")
        await #expect(throws: RecipeError.duplicateSlashCommand(command: "/risks", usedBy: "Risks")) {
            try await store.saveCustomRecipe(name: "Other", slashCommand: "risks", prompt: "p")
        }
        // Editing a recipe keeps its own command.
        try await store.saveCustomRecipe(id: first.id, name: "Risks v2", slashCommand: "/risks", prompt: "q")
        #expect(try await store.recipes().filter { $0.slashCommand == "/risks" }.map(\.name) == ["Risks v2"])
    }

    @Test func invalidOrBuiltinEditsAreRejected() async throws {
        let (store, _) = try makeTempStore()
        try await RecipeLibrary.seed(store: store)
        await #expect(throws: RecipeError.invalidSlashCommand("/")) {
            try await store.saveCustomRecipe(name: "X", slashCommand: "/", prompt: "p")
        }
        await #expect(throws: RecipeError.invalidSlashCommand("/two words")) {
            try await store.saveCustomRecipe(name: "X", slashCommand: "/two words", prompt: "p")
        }
        await #expect(throws: RecipeError.builtinNotEditable("Decisions")) {
            try await store.saveCustomRecipe(id: "decisions", name: "Mine", slashCommand: "/dec2", prompt: "p")
        }
    }
}
