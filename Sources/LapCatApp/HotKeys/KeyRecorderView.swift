import AppKit
import Carbon.HIToolbox
import LapCatCore
import SwiftUI

/// Settings row that captures a new key combination for one action.
struct KeyRecorderView: View {
    let action: HotKeyAction
    @Environment(AppState.self) private var appState
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        HStack {
            Text(action.displayName)
            Spacer()
            Button(recording ? "Type shortcut…" : appState.hotKeys[action].displayString) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func start() {
        error = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let mods = Self.carbonModifiers(event.modifierFlags)
            guard mods != 0 else {
                error = "Use at least one modifier (⌃ ⌥ ⇧ ⌘)."
                return nil
            }
            let key = HotKey(keyCode: UInt32(event.keyCode), modifiers: mods)
            do throws(HotKeyBindings.AssignError) {
                try appState.updateHotKey(key, for: action)
                error = nil
            } catch let failure {
                switch failure {
                case .alreadyUsed(let other): error = "Already used by \(other.displayName)."
                }
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= HotKey.cmd }
        if flags.contains(.option) { mods |= HotKey.option }
        if flags.contains(.control) { mods |= HotKey.control }
        if flags.contains(.shift) { mods |= HotKey.shift }
        return mods
    }
}
