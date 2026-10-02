import AppKit
import LapCatCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyCenter.shared.setHandler(for: .open) { [appState] in appState.showMainWindow() }
        HotKeyCenter.shared.register(appState.hotKeys)
        if !appState.onboardingCompleted { appState.showPermissions() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
    }
}
