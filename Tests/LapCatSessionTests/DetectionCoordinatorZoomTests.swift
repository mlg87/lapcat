import Foundation
import LapCatCore
import Testing
import os

@testable import LapCatAudio
@testable import LapCatSession

/// The Zoom prompt → accept → auto-stop path of `DetectionCoordinator` (plan §9.3–9.4) over a scripted
/// monitor, a virtual clock and a recording notifier.
@MainActor @Suite struct DetectionCoordinatorZoomTests {
    private let sandbox = DefaultsSandbox()
    private let clock = VirtualClock()
    private let monitors = OSAllocatedUnfairLock<[FakeMonitor]>(initialState: [])
    private let session = FakeRecordingSession()
    private let notifier = RecordedNotifier()

    private var monitor: FakeMonitor { monitors.withLock { $0.last! } }

    private func coordinator(
        settings: AppSettings? = nil,
        calendar: @escaping @MainActor @Sendable (ClosedRange<TimeInterval>, Date) -> CalendarEventInfo? = { _, _ in
            nil
        }
    ) -> DetectionCoordinator {
        let detection = makeDetection(
            settings: settings ?? sandbox.settings(), session: session, clock: clock, notifier: notifier,
            monitors: monitors, calendar: calendar)
        detection.reconfigure()
        return detection
    }

    private func pricingReview(url: String? = "https://acme.zoom.us/j/123?pwd=x") -> CalendarEventInfo {
        CalendarEventInfo(
            id: "evt-1", title: "Pricing review", conferenceURL: url.flatMap(URL.init(string:)),
            start: clock.now.addingTimeInterval(-60), end: clock.now.addingTimeInterval(1800))
    }

    /// Accepts the Zoom prompt and waits until the session records with auto-stop armed for pid 500.
    private func acceptZoomPrompt(_ detection: DetectionCoordinator) async throws {
        monitor.send(zoomActivity(running: true))
        try #require(await eventually { detection.pending?.id == "pid-500" })
        detection.accept()
        try #require(await eventually { session.starts.count == 1 && detection.autoStopPID == 500 })
    }

    @Test func zoomTakingTheMicPromptsWithTheZoomSource() async throws {
        let detection = coordinator()
        monitor.send(zoomActivity(running: true))
        try #require(await eventually { detection.pending != nil })
        let prompt = try #require(detection.pending)
        #expect(prompt.id == "pid-500")
        #expect(prompt.title == "zoom.us")
        #expect(prompt.appName == "zoom.us")
        #expect(prompt.source == zoomSource)
        #expect(prompt.calendarEvent == nil)
        #expect(
            notifier.prompts == [
                .init(id: "pid-500", title: "Record \"zoom.us\"?", body: "zoom.us is using your microphone.")
            ])
    }

    @Test func overlappingCalendarEventTitlesThePromptAndTheNote() async throws {
        let event = pricingReview()
        let windows = OSAllocatedUnfairLock<[ClosedRange<TimeInterval>]>(initialState: [])
        let detection = coordinator { window, _ in
            windows.withLock { $0.append(window) }
            return event
        }
        monitor.send(zoomActivity(running: true))
        try #require(await eventually { detection.pending != nil })
        #expect(detection.pending?.title == "Pricing review")
        #expect(detection.pending?.calendarEvent?.id == "evt-1")
        #expect(detection.pending?.source == zoomSource)
        #expect(windows.withLock { $0 } == [CalendarService.defaultWindow])
        #expect(notifier.prompts.map(\.title) == ["Record \"Pricing review\"?"])

        detection.accept()
        try #require(await eventually { session.starts.count == 1 })
        #expect(
            session.starts == [.init(title: "Pricing review", source: zoomSource, startedBy: .prompt, event: event)])
    }

    @Test func acceptStartsAPromptedNoteForZoom() async throws {
        let detection = coordinator()
        monitor.send(zoomActivity(running: true))
        try #require(await eventually { detection.pending != nil })
        detection.accept()
        try #require(await eventually { session.starts.count == 1 })
        #expect(session.starts == [.init(title: nil, source: zoomSource, startedBy: .prompt, event: nil)])
        #expect(detection.pending == nil)
        #expect(notifier.removed == [["pid-500"]])
    }

    @Test func notNowSuppressesThatProcessForTenMinutes() async throws {
        let detection = coordinator()
        monitor.send(zoomActivity(running: true))
        try #require(await eventually { detection.pending != nil })
        detection.dismiss()
        #expect(notifier.removed == [["pid-500"]])

        clock.now += 599
        monitor.send(zoomActivity(running: true))
        // A second Zoom process proves the suppressed event was handled before it.
        monitor.send(zoomActivity(pid: 600, running: true))
        try #require(await eventually { detection.pending?.id == "pid-600" })

        clock.now += 2
        monitor.send(zoomActivity(running: true))
        try #require(await eventually { detection.pending?.id == "pid-500" })
        #expect(notifier.prompts.map(\.id) == ["pid-500", "pid-600", "pid-500"])
    }

    @Test func repeatedMicOnForTheSameProcessNotifiesOnce() async throws {
        let detection = coordinator()
        monitor.send(zoomActivity(running: true))
        monitor.send(zoomActivity(running: true))
        monitor.send(zoomActivity(pid: 600, running: true))
        try #require(await eventually { detection.pending?.id == "pid-600" })
        #expect(notifier.prompts.map(\.id) == ["pid-500", "pid-600"])
    }

    @Test func noPromptWhileARecordingRuns() async throws {
        let detection = coordinator()
        session.state = .recording(meetingID: "manual", startedAt: clock.now, paused: false)
        monitor.send(zoomActivity(running: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(detection.pending == nil)
        #expect(notifier.prompts.isEmpty)
    }

    @Test func micOffNeverPrompts() async throws {
        let detection = coordinator()
        monitor.send(zoomActivity(running: false))
        monitor.send(zoomActivity(pid: 600, running: true))
        try #require(await eventually { detection.pending?.id == "pid-600" })
        #expect(notifier.prompts.map(\.id) == ["pid-600"])
    }

    @Test func promptedZoomNoteStopsSixtySecondsAfterZoomReleasesTheMic() async throws {
        let detection = coordinator()
        try await acceptZoomPrompt(detection)
        let released = clock.now
        monitor.send(zoomActivity(running: false))
        try #require(await eventually { session.endCount == 1 })
        #expect(clock.now.timeIntervalSince(released) == 60)
        #expect(notifier.infos.last?.title == "Meeting ended — recording stopped")
        #expect(notifier.infos.last?.body == "The meeting app stopped using your microphone.")
        #expect(detection.autoStopPID == nil)
    }

    @Test func zoomTakingTheMicBackCancelsTheAutoStop() async throws {
        let detection = coordinator()
        try await acceptZoomPrompt(detection)
        clock.autoAdvance = false
        monitor.send(zoomActivity(running: false))
        try #require(await eventually { clock.parkedCount == 1 })
        monitor.send(zoomActivity(running: true))
        try await Task.sleep(for: .milliseconds(100))
        clock.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.endCount == 0)
        #expect(notifier.infos.isEmpty)
        #expect(detection.autoStopPID == 500)
    }

    @Test func manualNotesNeverAutoStop() async throws {
        _ = coordinator()
        session.state = .recording(meetingID: "manual", startedAt: clock.now, paused: false)
        clock.autoAdvance = false
        monitor.send(zoomActivity(running: false))
        try await Task.sleep(for: .milliseconds(200))
        #expect(clock.parkedCount == 0)
        #expect(session.endCount == 0)
    }

    @Test func zoomCalendarEventPromptsOnceWithoutASource() async throws {
        let event = pricingReview()
        let windows = OSAllocatedUnfairLock<[ClosedRange<TimeInterval>]>(initialState: [])
        let detection = coordinator { window, _ in
            windows.withLock { $0.append(window) }
            return event
        }
        await detection.checkCalendar()
        await detection.checkCalendar()
        #expect(detection.pending?.id == "event-evt-1")
        #expect(detection.pending?.appName == "Zoom")
        #expect(detection.pending?.source == nil)
        #expect(
            notifier.prompts == [
                .init(id: "event-evt-1", title: "Record \"Pricing review\"?", body: "Zoom meeting starting now.")
            ])
        #expect(windows.withLock { $0.first } == 0...60)
    }

    @Test func calendarEventWithoutALinkOrWithTheSignalOffDoesNotPrompt() async {
        let noLink = pricingReview(url: nil)
        await coordinator { _, _ in noLink }.checkCalendar()

        let settings = sandbox.settings()
        settings.detectUseCalendarSignal = false
        let event = pricingReview()
        await coordinator(settings: settings) { _, _ in event }.checkCalendar()
        #expect(notifier.prompts.isEmpty)
    }

    @Test func meetCalendarLinkNamesGoogleMeet() async {
        let event = pricingReview(url: "https://meet.google.com/abc-defg-hij")
        let detection = coordinator { _, _ in event }
        await detection.checkCalendar()
        #expect(detection.pending?.appName == "Google Meet")
        #expect(notifier.prompts.map(\.body) == ["Google Meet meeting starting now."])
    }

    @Test func settingsChangesStopOrRetargetTheMonitor() {
        let settings = sandbox.settings()
        let detection = coordinator(settings: settings)
        #expect(monitor.started)

        settings.detectBundleIDs = ["us.zoom.xos"]
        detection.reconfigure()
        #expect(monitors.withLock(\.count) == 1)
        #expect(monitor.bundleIDHistory.last == ["us.zoom.xos"])

        settings.detectEnabled = false
        detection.reconfigure()
        #expect(monitor.stopped)
    }
}
