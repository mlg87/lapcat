import LapCatCore
import Observation
import SwiftUI

/// App-wide state; one instance, injected with `.environment(appState)`.
@Observable @MainActor
final class AppState {
    let settings: AppSettings
    let store: Store
    let llm: LLMServices
    private(set) var permissionStatuses: [Permission: PermissionStatus] = [:]
    @ObservationIgnored private let windows = WindowPresenter()

    init(settings: AppSettings, store: Store) {
        self.settings = settings
        self.store = store
        self.llm = LLMServices(settings: settings)
    }

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
