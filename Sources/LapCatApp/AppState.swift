import LapCatCore
import LapCatSpeech
import Observation
import os
import SwiftUI

/// App-wide state; one instance, injected with `.environment(appState)`.
@Observable @MainActor
final class AppState {
    let settings: AppSettings
    let store: Store
    let llm: LLMServices
    let speech: SpeechServices
    let session: SessionController
    let pipeline: PostMeetingPipeline
    let detection: DetectionCoordinator
    private(set) var permissionStatuses: [Permission: PermissionStatus] = [:]
    /// Last start/stop failure, shown in the menu.
    private(set) var sessionError: String?
    @ObservationIgnored private let windows = WindowPresenter()
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "AppState")

    init(settings: AppSettings, store: Store) {
        self.settings = settings
        self.store = store
        let llm = LLMServices(settings: settings)
        self.llm = llm
        let speech = SpeechServices()
        self.speech = speech
        let session = SessionController(store: store, settings: settings, speech: speech)
        self.session = session
        let pipeline = PostMeetingPipeline(store: store, speech: speech) { @MainActor in
            PipelineConfig(
                speech: session.speechConfig, offlineOnly: settings.llmOfflineOnly, retention: settings.audioRetention,
                meName: settings.userDisplayName, defaultTemplateID: settings.templateDefaultID,
                autoExportFolder: settings.exportAutoExportFolder.map { URL(fileURLWithPath: $0, isDirectory: true) },
                router: llm.router)
        }
        self.pipeline = pipeline
        let detection = DetectionCoordinator(session: session, settings: settings)
        self.detection = detection
        session.onEnded = { meetingID in
            detection.sessionEnded()
            Task { await pipeline.enqueue(meetingID) }
        }
        SpeechServices.setOffline(settings.llmOfflineOnly)
    }

    /// Launch: built-in templates and recipes are (re)seeded, custom templates rescanned.
    func seedLibraries() async {
        do {
            try await TemplateLibrary.sync(store: store, customDirectory: Paths.standard.templates)
            try await RecipeLibrary.seed(store: store)
        } catch {
            Self.logger.error("seeding templates/recipes failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Launch: meetings interrupted mid-recording or mid-processing resume processing.
    func resumeInterruptedMeetings() async {
        do {
            for id in try await store.recoverInterruptedMeetings() { await pipeline.enqueue(id) }
        } catch {
            Self.logger.error("crash recovery failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Loads the live transcription model in the background (when it is already downloaded)
    /// so the first utterance of the first recording does not wait for it.
    func warmUpLiveEngine() {
        let config = session.speechConfig
        guard let file = EngineSelector(config: config).liveEngine().requiredModelFile,
              FileManager.default.fileExists(atPath: config.modelsDirectory.appendingPathComponent(file).path)
        else { return }
        let speech = speech
        Task.detached(priority: .utility) {
            try? await speech.liveEngine(config: config).load()
        }
    }

    func startNewNote() {
        guard session.state == .idle else {
            showMainWindow()
            return
        }
        Task {
            do {
                sessionError = nil
                try await session.startNewNote()
            } catch {
                sessionError = "Could not start recording: \(error)"
                Self.logger.error("start failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func togglePause() { Task { await session.togglePause() } }
    func endSession() { Task { await session.end() } }

    var hotKeys: HotKeyBindings { settings.hotKeys }

    var onboardingCompleted: Bool {
        get { settings.onboardingCompleted }
        set { settings.onboardingCompleted = newValue }
    }

    func updateHotKey(_ key: HotKey, for action: HotKeyAction) throws(HotKeyBindings.AssignError) {
        var bindings = settings.hotKeys
        try bindings.assign(key, to: action)
        settings.hotKeys = bindings
        HotKeyCenter.shared.register(bindings)
    }

    func refreshPermissions() async {
        var statuses: [Permission: PermissionStatus] = [:]
        for permission in Permission.allCases {
            statuses[permission] = await Permissions.status(permission)
        }
        permissionStatuses = statuses
    }

    func showMainWindow() {
        windows.show(id: WindowID.main, title: "LapCat", size: NSSize(width: 1000, height: 680), resizable: true) {
            MainWindow().environment(self)
        }
    }

    /// Settings is hosted like the other windows: a SwiftUI `Settings` scene opened from a
    /// menu-bar-only app is created offscreen behind the active app.
    func showSettings() {
        windows.show(id: WindowID.settings, title: "LapCat Settings", size: NSSize(width: 680, height: 560), resizable: false) {
            SettingsView().environment(self)
        }
    }

    func showPermissions() {
        windows.show(id: WindowID.permissions, title: "LapCat Permissions", size: NSSize(width: 620, height: 560), resizable: false) {
            PermissionsView().environment(self)
        }
    }

    func closePermissions() {
        windows.close(id: WindowID.permissions)
    }
}

enum WindowID {
    static let main = "main"
    static let settings = "settings"
    static let permissions = "permissions"
}
