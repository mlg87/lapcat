import AppKit
import Foundation
import LapCatAudio
import LapCatCore
import Observation
import UserNotifications
import os

/// Notices meetings and asks whether to record them (plan §9.3); never records without a click.
///
/// Signals: a watched app starts using the microphone; a calendar event with a conference link
/// starts; (opt-in) the frontmost browser tab is a Google Meet call. A prompted session stops on
/// its own once its app has not used the microphone for 60 s (§9.4); manual sessions never do.
@Observable @MainActor
final class DetectionCoordinator: NSObject, UNUserNotificationCenterDelegate {
    struct Prompt: Equatable, Identifiable {
        var id: String
        var title: String
        var appName: String
        var source: SessionSource?
        var calendarEvent: CalendarEventInfo?

        static func == (a: Prompt, b: Prompt) -> Bool { a.id == b.id }
    }

    /// Shown as a "Record '…'?" menu item while pending (for people who turn notifications off).
    private(set) var pending: Prompt?

    @ObservationIgnored private let session: SessionController
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var monitor: AudioInputActivityMonitor?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var suppressedUntil: [pid_t: Date] = [:]
    @ObservationIgnored private var promptedEvents: Set<String> = []
    @ObservationIgnored private var promptedTabs: Set<String> = []
    @ObservationIgnored private var autoStop = AutoStopTracker()
    @ObservationIgnored private var autoStopPID: pid_t?
    @ObservationIgnored private var autoStopTimer: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "DetectionCoordinator")
    private static let category = "LAPCAT_DETECT"
    private static let recordAction = "RECORD"
    private static let notNowAction = "NOT_NOW"

    init(session: SessionController, settings: AppSettings) {
        self.session = session
        self.settings = settings
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [.foreground]),
                    UNNotificationAction(identifier: Self.notNowAction, title: "Not now"),
                ],
                intentIdentifiers: [])
        ])
        reconfigure()
        observeSettings()
        tasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.checkCalendar()
                    try? await Task.sleep(for: .seconds(60))
                }
            })
        tasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.checkBrowserTabs()
                    try? await Task.sleep(for: .seconds(30))
                }
            })
    }

    /// Re-arms the microphone-activity monitor whenever the detection settings change.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.detectEnabled
            _ = settings.detectBundleIDs
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reconfigure()
                self?.observeSettings()
            }
        }
    }

    private func reconfigure() {
        // The monitor also feeds auto-stop, so it runs while a prompted session records even
        // if prompts are off.
        guard settings.detectEnabled else {
            monitor?.stop()
            monitor = nil
            return
        }
        if let monitor {
            monitor.setBundleIDs(settings.detectBundleIDs)
            return
        }
        let monitor = AudioInputActivityMonitor(bundleIDs: settings.detectBundleIDs)
        self.monitor = monitor
        monitor.start()
        tasks.append(
            Task { [weak self] in
                for await activity in monitor.activities { self?.handle(activity) }
            })
    }

    // MARK: Signals

    private func handle(_ activity: InputActivity) {
        if activity.pid == autoStopPID { trackAutoStop(isRunningInput: activity.isRunningInput) }
        guard activity.isRunningInput, session.state == .idle else { return }
        if let until = suppressedUntil[activity.pid], until > Date() { return }
        let appName = NSRunningApplication(processIdentifier: activity.pid)?.localizedName ?? activity.name
        let event = settings.detectUseCalendarSignal ? CalendarService().currentOrUpcomingEvent() : nil
        prompt(
            Prompt(
                id: "pid-\(activity.pid)", title: event?.title ?? appName, appName: appName,
                source: SessionSource(appName: appName, bundleID: activity.bundleID, pid: activity.pid),
                calendarEvent: event))
    }

    private func checkCalendar() async {
        guard settings.detectEnabled, settings.detectUseCalendarSignal, session.state == .idle,
            let event = CalendarService().currentOrUpcomingEvent(window: 0...60),
            event.conferenceURL != nil, !promptedEvents.contains(event.id)
        else { return }
        promptedEvents.insert(event.id)
        let platform = event.conferenceURL.flatMap(MeetingURLMatcher.platform(of:))
        prompt(
            Prompt(
                id: "event-\(event.id)", title: event.title, appName: platform == .zoom ? "Zoom" : "Google Meet",
                source: nil, calendarEvent: event))
    }

    private func checkBrowserTabs() async {
        guard settings.detectEnabled, settings.detectUseBrowserTabSignal, session.state == .idle else { return }
        let browsers = settings.detectBundleIDs.filter {
            BrowserTabProbe.chromiumBundleIDs.contains($0) || BrowserTabProbe.safariBundleIDs.contains($0)
        }
        for bundleID in browsers {
            guard let url = await BrowserTabProbe.activeURL(bundleID: bundleID) else { continue }
            Permissions.markGranted(.automation)
            guard let code = MeetingURLMatcher.meetCode(inTab: url), !promptedTabs.contains(code) else { continue }
            promptedTabs.insert(code)
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            prompt(
                Prompt(
                    id: "meet-\(code)", title: "Google Meet", appName: app?.localizedName ?? "Browser",
                    source: SessionSource(
                        appName: app?.localizedName ?? "Browser", bundleID: bundleID, pid: app?.processIdentifier),
                    calendarEvent: nil))
        }
    }

    // MARK: Prompts

    private func prompt(_ prompt: Prompt) {
        guard pending?.id != prompt.id else { return }
        pending = prompt
        let content = UNMutableNotificationContent()
        content.title = "Record \"\(prompt.title)\"?"
        content.body =
            prompt.source != nil
            ? "\(prompt.appName) is using your microphone."
            : "\(prompt.appName) meeting starting now."
        content.categoryIdentifier = Self.category
        content.userInfo = ["promptID": prompt.id]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: prompt.id, content: content, trigger: nil))
        Self.logger.notice("prompted \(prompt.id, privacy: .public)")
    }

    /// The menu's "Record '…'?" item and the notification's Record action.
    func accept() {
        guard let prompt = pending else { return }
        pending = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [prompt.id])
        Task {
            do {
                try await session.startNewNote(
                    title: prompt.calendarEvent?.title, source: prompt.source,
                    startedBy: .prompt, calendarEvent: prompt.calendarEvent)
                autoStop = AutoStopTracker()
                autoStopPID = prompt.source?.pid
            } catch {
                Self.logger.error("prompted start failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// "Not now": no more prompts for that process for 10 minutes.
    func dismiss() {
        guard let prompt = pending else { return }
        pending = nil
        if let pid = prompt.source?.pid { suppressedUntil[pid] = Date().addingTimeInterval(600) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [prompt.id])
    }

    // MARK: Auto-stop

    private func trackAutoStop(isRunningInput: Bool) {
        guard case .recording = session.state, autoStopPID != nil else { return }
        if autoStop.observe(isRunningInput: isRunningInput, now: Date()) == .shouldStop {
            stopForInactivity()
            return
        }
        autoStopTimer?.cancel()
        guard let deadline = autoStop.stopDeadline else { return }
        autoStopTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.trackAutoStop(isRunningInput: false)
        }
    }

    private func stopForInactivity() {
        autoStopPID = nil
        autoStopTimer?.cancel()
        let content = UNMutableNotificationContent()
        content.title = "Meeting ended — recording stopped"
        content.body = "The meeting app stopped using your microphone."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "autostop-\(UUID().uuidString)", content: content, trigger: nil))
        Task { await session.end() }
    }

    /// Called when a session ends for any reason: a manual End clears auto-stop tracking.
    func sessionEnded() {
        autoStopPID = nil
        autoStopTimer?.cancel()
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let promptID = response.notification.request.content.userInfo["promptID"] as? String
        await MainActor.run {
            guard let promptID, self.pending?.id == promptID else { return }
            switch action {
            case Self.recordAction, UNNotificationDefaultActionIdentifier: self.accept()
            case Self.notNowAction, UNNotificationDismissActionIdentifier: self.dismiss()
            default: break
            }
        }
    }
}
