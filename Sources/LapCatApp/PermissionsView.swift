import LapCatCore
import SwiftUI

struct PermissionsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LapCat needs a few permissions").font(.title2.bold())
            Text("Grant what you need now; you can come back here from Settings → General.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, status: appState.permissionStatuses[permission] ?? .unknown)
                }
            }
            HStack {
                Button("Refresh") { Task { await appState.refreshPermissions() } }
                Spacer()
                Button("Done") {
                    appState.onboardingCompleted = true
                    appState.closePermissions()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .task { await appState.refreshPermissions() }
        // Grants usually happen in System Settings; re-query when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await appState.refreshPermissions() }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    @Environment(AppState.self) private var appState

    var body: some View {
        GridRow {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading) {
                Text(permission.displayName).bold()
                Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
            }
            Text(label).font(.caption).foregroundStyle(color)
            HStack {
                Button("Grant") {
                    Task {
                        await Permissions.request(permission)
                        await appState.refreshPermissions()
                    }
                }
                .disabled(status == .granted)
                Button("Open System Settings") { Permissions.openSettings(permission) }
            }
        }
    }

    private var symbol: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined, .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .notDetermined, .unknown: .secondary
        }
    }

    private var label: String {
        switch status {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not asked"
        case .unknown: "Unknown"
        }
    }
}
