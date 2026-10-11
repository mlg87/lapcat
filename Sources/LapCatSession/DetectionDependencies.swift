import AppKit
import Foundation
import LapCatAudio
import LapCatCore
import UserNotifications

/// Posts the detection prompts. A seam so tests record them and `lapcat-dev`, which has no
/// `UNUserNotificationCenter`, logs them instead (#59).
public protocol PromptNotifier: Sendable {
    /// Registers the LAPCAT_DETECT category (RECORD "Record" foreground, NOT_NOW "Not now") and the delegate.
    @MainActor func activate(delegate: any UNUserNotificationCenterDelegate)
    /// Record-prompt notification: category LAPCAT_DETECT, userInfo ["promptID": id], request identifier id.
    @MainActor func postPrompt(id: String, title: String, body: String)
    /// Plain notification (auto-stop): request identifier id, no category.
    @MainActor func postInfo(id: String, title: String, body: String)
    @MainActor func removeDelivered(ids: [String])
}

/// The app's notifier. Each call looks up `UNUserNotificationCenter.current()` itself, so building
/// `DetectionDependencies.live` never touches the notification center.
public struct UserNotificationPromptNotifier: PromptNotifier {
    public static let category = "LAPCAT_DETECT"
    public static let recordAction = "RECORD"
    public static let notNowAction = "NOT_NOW"

    public init() {}

    public func activate(delegate: any UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [.foreground]),
                    UNNotificationAction(identifier: Self.notNowAction, title: "Not now"),
                ],
                intentIdentifiers: [])
        ])
    }

    public func postPrompt(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.category
        content.userInfo = ["promptID": id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    public func postInfo(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    public func removeDelivered(ids: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Everything `DetectionCoordinator` reaches outside the process for. `.live` is the app's wiring;
/// tests swap in a scripted monitor, a virtual clock and a recording notifier (#59).
public struct DetectionDependencies: Sendable {
    public var makeMonitor: @Sendable ([String]) -> any InputActivitySource
    public var calendarEvent:
        @MainActor @Sendable (_ window: ClosedRange<TimeInterval>, _ now: Date) -> CalendarEventInfo?
    public var appName: @Sendable (pid_t) -> String?
    public var notifier: any PromptNotifier
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async -> Void

    public init(
        makeMonitor: @escaping @Sendable ([String]) -> any InputActivitySource,
        calendarEvent:
            @escaping @MainActor @Sendable (_ window: ClosedRange<TimeInterval>, _ now: Date) ->
            CalendarEventInfo?,
        appName: @escaping @Sendable (pid_t) -> String?,
        notifier: any PromptNotifier,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async -> Void
    ) {
        self.makeMonitor = makeMonitor
        self.calendarEvent = calendarEvent
        self.appName = appName
        self.notifier = notifier
        self.now = now
        self.sleep = sleep
    }

    public static let live = DetectionDependencies(
        makeMonitor: { AudioInputActivityMonitor(bundleIDs: $0) },
        calendarEvent: { window, now in CalendarService().currentOrUpcomingEvent(window: window, now: now) },
        appName: { NSRunningApplication(processIdentifier: $0)?.localizedName },
        notifier: UserNotificationPromptNotifier(),
        now: { Date() },
        sleep: { try? await Task.sleep(for: $0) })
}
