import LapCatCore
import Observation
import SwiftUI

/// App-wide state; one instance, injected with `.environment(appState)`.
@Observable @MainActor
final class AppState {
    private(set) var hotKeys = HotKeyBindings.load()
    private(set) var permissionStatuses: [Permission: PermissionStatus] = [:]
    @ObservationIgnored private let windows = WindowPresenter()

    var onboardingCompleted: Bool {
        get { access(keyPath: \.onboardingCompleted); return UserDefaults.standard.bool(forKey: "onboarding.completed") }
        set { withMutation(keyPath: \.onboardingCompleted) { UserDefaults.standard.set(newValue, forKey: "onboarding.completed") } }
    }

    func updateHotKey(_ key: HotKey, for action: HotKeyAction) throws(HotKeyBindings.AssignError) {
        try hotKeys.assign(key, to: action)
        hotKeys.save()
        HotKeyCenter.shared.register(hotKeys)
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
    static let permissions = "permissions"
}
