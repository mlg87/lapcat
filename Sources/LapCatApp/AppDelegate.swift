import AppKit
import LapCatCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState = AppDelegate.makeAppState()

    private static func makeAppState() -> AppState {
        do {
            try Paths.standard.ensureDirectories()
            return AppState(settings: AppSettings(), store: try Store(databaseURL: Paths.standard.database))
        } catch {
            Logger(subsystem: "com.lapcat.app", category: "AppDelegate").fault("Cannot open the LapCat database: \(error)")
            let alert = NSAlert()
            alert.messageText = "LapCat can’t open its database"
            alert.informativeText = "\(Paths.standard.database.path)\n\n\(error.localizedDescription)"
            alert.runModal()
            exit(1)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyCenter.shared.setHandler(for: .open) { [appState] in appState.showMainWindow() }
        HotKeyCenter.shared.register(appState.hotKeys)
        if !appState.onboardingCompleted { appState.showPermissions() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
        appState.llm.shutdown()
    }
}
