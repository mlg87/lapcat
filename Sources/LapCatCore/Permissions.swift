import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import UserNotifications

public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case microphone, systemAudio, accessibility, calendars, notifications, automation, screenRecording

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio Recording"
        case .accessibility: "Accessibility"
        case .calendars: "Calendars"
        case .notifications: "Notifications"
        case .automation: "Automation (browser)"
        case .screenRecording: "Screen Recording"
        }
    }

    public var purpose: String {
        switch self {
        case .microphone: "Records your voice as the “Me” channel."
        case .systemAudio: "Records the meeting app’s audio as the “Them” channel."
        case .accessibility: "Reads Zoom/Meet participant names to label speakers."
        case .calendars: "Titles meetings and lists attendees."
        case .notifications: "Asks whether to record when a meeting starts."
        case .automation: "Reads the browser’s current tab to detect Google Meet."
        case .screenRecording: "Optional — fallback only, when the system audio tap fails."
        }
    }

    /// System Settings deep link for this pane.
    public var settingsURL: URL {
        let anchor =
            switch self {
            case .microphone: "Privacy_Microphone"
            case .systemAudio: "Privacy_AudioCapture"
            case .accessibility: "Privacy_Accessibility"
            case .calendars: "Privacy_Calendars"
            case .notifications: "Notifications"
            case .automation: "Privacy_Automation"
            case .screenRecording: "Privacy_ScreenCapture"
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionStatus: String, Sendable {
    case granted, denied, notDetermined, unknown
}

/// Queries and requests the TCC permissions LapCat needs.
///
/// System Audio has no public API; it goes through `SystemAudioTCC` (private TCC calls).
/// Automation has no query API: it reports `unknown` until a browser AppleScript probe
/// calls `markGranted`.
@MainActor
public enum Permissions {
    private static let observedKey = "permissions.observedGranted"

    public static func markGranted(_ permission: Permission) {
        var observed = Set(UserDefaults.standard.stringArray(forKey: observedKey) ?? [])
        observed.insert(permission.rawValue)
        UserDefaults.standard.set(Array(observed).sorted(), forKey: observedKey)
    }

    private static func observedGranted(_ permission: Permission) -> Bool {
        (UserDefaults.standard.stringArray(forKey: observedKey) ?? []).contains(permission.rawValue)
    }

    public static func status(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .calendars:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .denied, .restricted, .writeOnly: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .systemAudio:
            if let status = SystemAudioTCC.preflight() { return status }
            return observedGranted(permission) ? .granted : .unknown
        case .automation:
            return observedGranted(permission) ? .granted : .unknown
        }
    }

    /// Triggers the system prompt where one exists, otherwise opens System Settings.
    ///
    /// `systemAudioProbe` runs a short real process tap (public API; starting tap IO also makes
    /// macOS prompt). It is used only when the private TCC request is unavailable on this macOS.
    public static func request(
        _ permission: Permission, systemAudioProbe: (@Sendable () async -> Void)? = nil
    ) async {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .calendars:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .systemAudio:
            switch await SystemAudioTCC.request() {
            case true?: markGranted(.systemAudio)
            // Denied earlier: macOS will not prompt again; the toggle is in System Settings.
            case false?: openSettings(permission)
            case nil:
                if let systemAudioProbe { await systemAudioProbe() }
                openSettings(permission)
            }
        case .automation:
            openSettings(permission)
        }
    }

    public static func openSettings(_ permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
