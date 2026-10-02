import AppKit
import LapCatCore
import SwiftUI

/// Settings → Detection (meeting prompts) and the Calendar permission used for titles.
struct DetectionSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newBundleID = ""
    @State private var selection: String?

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section {
                Toggle("Ask to record when a meeting starts", isOn: $settings.detectEnabled)
                Text("LapCat never records without your click.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Apps that trigger a prompt when they use the microphone") {
                List(selection: $selection) {
                    ForEach(settings.detectBundleIDs, id: \.self) { id in
                        HStack {
                            Text(id).font(.system(.body, design: .monospaced))
                            if let name = Self.appName(bundleID: id) {
                                Text(name).foregroundStyle(.secondary)
                            }
                        }
                        .tag(id)
                    }
                }
                .frame(height: 130)
                HStack {
                    TextField("Bundle ID, e.g. com.microsoft.teams2", text: $newBundleID)
                        .onSubmit(addBundleID)
                    Button("Add", action: addBundleID).disabled(normalizedNewID == nil)
                    Button("Remove") {
                        settings.detectBundleIDs.removeAll { $0 == selection }
                        selection = nil
                    }
                    .disabled(selection == nil)
                    Button("Restore defaults") { settings.detectBundleIDs = AppSettings.Default.detectBundleIDs }
                        .disabled(settings.detectBundleIDs == AppSettings.Default.detectBundleIDs)
                }
            }
            Section("Other signals") {
                Toggle("Prompt when a calendar event with a Zoom/Meet link starts", isOn: $settings.detectUseCalendarSignal)
                Toggle("Prompt when the browser’s current tab is a Google Meet call", isOn: $settings.detectUseBrowserTabSignal)
                if settings.detectUseBrowserTabSignal && status(.automation) != .granted {
                    Text("Needs Automation permission for your browser; macOS asks the first time LapCat checks the tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Calendar") {
                LabeledContent("Access", value: status(.calendars).label)
                Text("LapCat reads your calendar to title meetings and list attendees; nothing is written to it.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Grant calendar access") {
                        Task {
                            await Permissions.request(.calendars)
                            await appState.refreshPermissions()
                        }
                    }
                    .disabled(status(.calendars) == .granted)
                    Button("Open System Settings") { Permissions.openSettings(.calendars) }
                }
            }
        }
        .formStyle(.grouped)
        .task { await appState.refreshPermissions() }
    }

    private func status(_ permission: Permission) -> PermissionStatus {
        appState.permissionStatuses[permission] ?? .unknown
    }

    private var normalizedNewID: String? {
        let id = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains(where: \.isWhitespace), !appState.settings.detectBundleIDs.contains(id) else { return nil }
        return id
    }

    private func addBundleID() {
        guard let id = normalizedNewID else { return }
        appState.settings.detectBundleIDs.append(id)
        newBundleID = ""
    }

    private static func appName(bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
    }
}

extension PermissionStatus {
    var label: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not asked"
        case .unknown: "Unknown"
        }
    }
}
