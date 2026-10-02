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
            MenuBarLabel(session: appDelegate.appState.session)
        }
    }
}

/// Cat when idle; record glyph plus elapsed mm:ss while recording.
///
/// The time comes from `SessionController.clock` (a 1 Hz observable tick), not a `TimelineView`:
/// a TimelineView in a MenuBarExtra label re-lays out the status item in a tight loop and
/// starves the main run loop (hotkeys and menu stop responding).
struct MenuBarLabel: View {
    let session: SessionController

    var body: some View {
        if case .recording(_, _, let paused) = session.state {
            Image(systemName: paused ? "pause.circle.fill" : "record.circle.fill")
            Text(Self.format(session.elapsed(at: session.clock)))
        } else {
            Image(systemName: "cat")
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let session = appState.session
        let keys = appState.hotKeys
        Text(statusLine)
        if let warning = session.warning { Text("⚠︎ \(warning)") }
        if let error = appState.sessionError { Text("⚠︎ \(error)") }
        Divider()
        switch session.state {
        case .idle:
            Button("New Note \(keys[.newNote].displayString)") { appState.startNewNote() }
        case .starting, .ending:
            EmptyView()
        case .recording(_, _, let paused):
            Button("\(paused ? "Resume" : "Pause") \(keys[.pauseResume].displayString)") { appState.togglePause() }
            Button("End \(keys[.end].displayString)") { appState.endSession() }
        }
        Button("Open LapCat \(keys[.open].displayString)") { appState.showMainWindow() }
        Divider()
        Button("Permissions…") { appState.showPermissions() }
        Button("Settings…") { appState.showSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit LapCat") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch appState.session.state {
        case .idle: "Not recording"
        case .starting: "Starting…"
        case .recording(_, _, let paused): paused ? "Paused" : "Recording"
        case .ending: "Finishing…"
        }
    }
}
