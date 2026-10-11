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
public final class DetectionCoordinator: NSObject, UNUserNotificationCenterDelegate {
    public struct Prompt: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var appName: String
        public var source: SessionSource?
        public var calendarEvent: CalendarEventInfo?

        public static func == (a: Prompt, b: Prompt) -> Bool { a.id == b.id }
    }

    /// Shown as a "Record '…'?" menu item while pending (for people who turn notifications off).
    public private(set) var pending: Prompt?

    @ObservationIgnored private let session: any RecordingSession
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let dependencies: DetectionDependencies
    @ObservationIgnored private var monitor: (any InputActivitySource)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var suppressedUntil: [pid_t: Date] = [:]
    @ObservationIgnored private var promptedEvents: Set<String> = []
    @ObservationIgnored private var promptedTabs: Set<String> = []
    @ObservationIgnored private var autoStop = AutoStopTracker()
    @ObservationIgnored private(set) var autoStopPID: pid_t?
    @ObservationIgnored private var autoStopTimer: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "DetectionCoordinator")

    public init(session: any RecordingSession, settings: AppSettings, dependencies: DetectionDependencies = .live) {
        self.session = session
        self.settings = settings
        self.dependencies = dependencies
        super.init()
    }

    public func start() {
        dependencies.notifier.activate(delegate: self)
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

    func reconfigure() {
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
        let monitor = dependencies.makeMonitor(settings.detectBundleIDs)
        self.monitor = monitor
        monitor.start()
        tasks.append(
            Task { [weak self] in
                for await activity in monitor.activities { self?.handle(activity) }
            })
    }

    // MARK: Signals

    func handle(_ activity: InputActivity) {
        if activity.pid == autoStopPID { trackAutoStop(isRunningInput: activity.isRunningInput) }
        guard activity.isRunningInput, session.state == .idle else { return }
        let now = dependencies.now()
        if let until = suppressedUntil[activity.pid], until > now { return }
        let appName = dependencies.appName(activity.pid) ?? activity.name
        let event =
            settings.detectUseCalendarSignal ? dependencies.calendarEvent(CalendarService.defaultWindow, now) : nil
        prompt(
            Prompt(
                id: "pid-\(activity.pid)", title: event?.title ?? appName, appName: appName,
                source: SessionSource(appName: appName, bundleID: activity.bundleID, pid: activity.pid),
                calendarEvent: event))
    }

    func checkCalendar() async {
        guard settings.detectEnabled, settings.detectUseCalendarSignal, session.state == .idle,
            let event = dependencies.calendarEvent(0...60, dependencies.now()),
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
        dependencies.notifier.postPrompt(
            id: prompt.id, title: "Record \"\(prompt.title)\"?",
            body: prompt.source != nil
                ? "\(prompt.appName) is using your microphone."
                : "\(prompt.appName) meeting starting now.")
        Self.logger.notice("prompted \(prompt.id, privacy: .public)")
    }

    /// The menu's "Record '…'?" item and the notification's Record action.
    public func accept() {
        guard let prompt = pending else { return }
        pending = nil
        dependencies.notifier.removeDelivered(ids: [prompt.id])
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
    public func dismiss() {
        guard let prompt = pending else { return }
        pending = nil
        if let pid = prompt.source?.pid { suppressedUntil[pid] = dependencies.now().addingTimeInterval(600) }
        dependencies.notifier.removeDelivered(ids: [prompt.id])
    }

    // MARK: Auto-stop

    func trackAutoStop(isRunningInput: Bool) {
        guard case .recording = session.state, autoStopPID != nil else { return }
        if autoStop.observe(isRunningInput: isRunningInput, now: dependencies.now()) == .shouldStop {
            stopForInactivity()
            return
        }
        autoStopTimer?.cancel()
        guard let deadline = autoStop.stopDeadline else { return }
        let dependencies = dependencies
        autoStopTimer = Task { [weak self] in
            await dependencies.sleep(.seconds(max(0, deadline.timeIntervalSince(dependencies.now()))))
            guard !Task.isCancelled else { return }
            self?.trackAutoStop(isRunningInput: false)
        }
    }

    private func stopForInactivity() {
        autoStopPID = nil
        autoStopTimer?.cancel()
        dependencies.notifier.postInfo(
            id: "autostop-\(UUID().uuidString)", title: "Meeting ended — recording stopped",
            body: "The meeting app stopped using your microphone.")
        Task { await session.end() }
    }

    /// Called when a session ends for any reason: a manual End clears auto-stop tracking.
    public func sessionEnded() {
        autoStopPID = nil
        autoStopTimer?.cancel()
    }

    // MARK: UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let promptID = response.notification.request.content.userInfo["promptID"] as? String
        await MainActor.run {
            guard let promptID, self.pending?.id == promptID else { return }
            switch action {
            case UserNotificationPromptNotifier.recordAction, UNNotificationDefaultActionIdentifier: self.accept()
            case UserNotificationPromptNotifier.notNowAction, UNNotificationDismissActionIdentifier: self.dismiss()
            default: break
            }
        }
    }
}
