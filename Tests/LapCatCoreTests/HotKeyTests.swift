import Foundation
import Testing
@testable import LapCatCore

struct HotKeyBindingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "lapcat.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsAreTheFourControlOptionCombos() {
        let bindings = HotKeyBindings.load(from: freshDefaults())
        #expect(bindings[.newNote].displayString == "⌃⌥N")
        #expect(bindings[.end].displayString == "⌃⌥E")
        #expect(bindings[.pauseResume].displayString == "⌃⌥P")
        #expect(bindings[.open].displayString == "⌃⌥L")
    }

    @Test func assigningAComboUsedByAnotherActionIsRejectedAndLeavesBindingsUnchanged() {
        var bindings = HotKeyBindings.load(from: freshDefaults())
        let before = bindings
        #expect(throws: HotKeyBindings.AssignError.alreadyUsed(by: .end)) {
            try bindings.assign(HotKeyAction.end.defaultHotKey, to: .newNote)
        }
        #expect(bindings == before)
    }

    @Test func reassigningAnActionToItsOwnComboIsAllowed() throws {
        var bindings = HotKeyBindings.load(from: freshDefaults())
        try bindings.assign(HotKeyAction.open.defaultHotKey, to: .open)
        #expect(bindings[.open] == HotKeyAction.open.defaultHotKey)
    }

    @Test func savedBindingsRoundTripThroughUserDefaults() throws {
        let defaults = freshDefaults()
        var bindings = HotKeyBindings.load(from: defaults)
        let custom = HotKey(keyCode: 0x01, modifiers: HotKey.cmd | HotKey.shift)
        try bindings.assign(custom, to: .newNote)
        bindings.save(to: defaults)
        #expect(HotKeyBindings.load(from: defaults)[.newNote] == custom)
        #expect(HotKeyBindings.load(from: defaults)[.newNote].displayString == "⇧⌘S")
    }
}
