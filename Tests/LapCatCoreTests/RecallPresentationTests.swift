import Foundation
import Testing

@testable import LapCatCore

struct SearchSnippetTests {
    private func boldRuns(_ text: AttributedString) -> [String] {
        text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map {
            String(text[$0.range].characters)
        }
    }

    @Test func boldTagsBecomeEmphasisAndAreRemoved() {
        let text = SearchSnippet.attributed("…we talked <b>pricing</b> and <b>pricing</b> tiers…")
        #expect(String(text.characters) == "…we talked pricing and pricing tiers…")
        #expect(boldRuns(text) == ["pricing", "pricing"])
    }

    @Test func whitespaceAndNewlinesCollapse() {
        let text = SearchSnippet.attributed("\n## Notes\n\n- <b>price</b>   list \n")
        #expect(String(text.characters) == "## Notes - price list")
        #expect(boldRuns(text) == ["price"])
    }

    @Test func unclosedTagEmphasizesToEndAndStrayCloseIsDropped() {
        let text = SearchSnippet.attributed("a</b> b <b>c d")
        #expect(String(text.characters) == "a b c d")
        #expect(boldRuns(text) == ["c d"])
    }
}

struct SearchHitTargetTests {
    private func hit(_ kind: SearchKind, _ ref: String) -> SearchHit {
        SearchHit(meetingID: "m1", kind: kind, refID: ref, snippet: "", rank: 0)
    }

    @Test func eachKindOpensItsTab() {
        #expect(SearchHitTarget(hit(.segment, "42")) == .transcript(segmentID: 42))
        #expect(SearchHitTarget(hit(.raw, "m1")) == .notes)
        #expect(SearchHitTarget(hit(.enhanced, "7")) == .enhanced)
        #expect(SearchHitTarget(hit(.person, "3")) == .meeting)
        #expect(SearchHitTarget(hit(.title, "m1")) == .meeting)
        #expect(SearchHitTarget(hit(.segment, "not-a-number")) == .meeting)
    }
}

struct RecipeFilterTests {
    private let recipes = [
        Recipe(
            id: "follow-up-email", name: "Follow-up email", slashCommand: "/follow-up", prompt: "Draft", isBuiltin: true
        ),
        Recipe(id: "action-items", name: "Action items", slashCommand: "/actions", prompt: "List", isBuiltin: true),
        Recipe(id: "custom:fun", name: "Fun", slashCommand: "/fun", prompt: "Joke", isBuiltin: false),
    ]

    @Test func slashAloneListsEveryRecipe() {
        #expect(
            RecipeFilter.suggestions(for: "/", in: recipes)?.map(\.id) == [
                "follow-up-email", "action-items", "custom:fun",
            ])
    }

    @Test func prefixFiltersCaseInsensitively() {
        #expect(RecipeFilter.suggestions(for: "/F", in: recipes)?.map(\.id) == ["follow-up-email", "custom:fun"])
        #expect(RecipeFilter.suggestions(for: "/fol", in: recipes)?.map(\.id) == ["follow-up-email"])
        #expect(RecipeFilter.suggestions(for: "/zzz", in: recipes) == [])
    }

    @Test func pickerIsHiddenForOrdinaryTextOrOnceArgumentsFollow() {
        #expect(RecipeFilter.suggestions(for: "what is /follow-up", in: recipes) == nil)
        #expect(RecipeFilter.suggestions(for: "/follow-up please", in: recipes) == nil)
        #expect(RecipeFilter.suggestions(for: "", in: recipes) == nil)
    }

    @Test func exactCommandResolvesToItsRecipe() {
        #expect(RecipeFilter.recipe(matching: " /Follow-Up ", in: recipes)?.id == "follow-up-email")
        #expect(RecipeFilter.recipe(matching: "/follow", in: recipes) == nil)
    }
}
