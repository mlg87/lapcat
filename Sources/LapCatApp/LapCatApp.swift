import LapCatCore
import SwiftUI

@main
struct LapCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.appState)
        } label: {
            Image(systemName: "cat")
        }

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button("Open LapCat \(appState.hotKeys[.open].displayString)") { appState.showMainWindow() }
        Button("Permissions…") { appState.showPermissions() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit LapCat") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
