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
            Logger(subsystem: "com.lapcat.app", category: "AppDelegate").fault(
                "Cannot open the LapCat database: \(error)")
            let alert = NSAlert()
            alert.messageText = "LapCat can’t open its database"
            alert.informativeText = "\(Paths.standard.database.path)\n\n\(error.localizedDescription)"
            alert.runModal()
            exit(1)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = appState
        HotKeyCenter.shared.setHandler(for: .open) { state.showMainWindow() }
        HotKeyCenter.shared.setHandler(for: .newNote) { state.startNewNote() }
        HotKeyCenter.shared.setHandler(for: .end) { state.endSession() }
        HotKeyCenter.shared.setHandler(for: .pauseResume) { state.togglePause() }
        HotKeyCenter.shared.register(appState.hotKeys)
        if !appState.onboardingCompleted { appState.showPermissions() }
        Task {
            await state.seedLibraries()
            await state.resumeInterruptedMeetings()
            state.scheduleRetentionSweeps()
        }
        state.warmUpLiveEngine()
        state.detection.start()
        state.updates.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
        appState.llm.shutdown()
    }
}
