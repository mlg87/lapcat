import CoreAudio
import Foundation
import LapCatCore
import LapCatSpeakers
import UserNotifications
import os

@testable import LapCatAudio
@testable import LapCatSession

/// Scripted microphone-activity monitor.
final class FakeMonitor: InputActivitySource, Sendable {
    let activities: AsyncStream<InputActivity>
    private let continuation: AsyncStream<InputActivity>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: (started: false, stopped: false, bundleIDs: [[String]]()))

    init(bundleIDs: [String]) {
        (activities, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        state.withLock { $0.bundleIDs.append(bundleIDs) }
    }

    var started: Bool { state.withLock(\.started) }
    var stopped: Bool { state.withLock(\.stopped) }
    var bundleIDHistory: [[String]] { state.withLock(\.bundleIDs) }

    func send(_ activity: InputActivity) { continuation.yield(activity) }

    func start() { state.withLock { $0.started = true } }

    func stop() {
        state.withLock { $0.stopped = true }
        continuation.finish()
    }

    func setBundleIDs(_ bundleIDs: [String]) { state.withLock { $0.bundleIDs.append(bundleIDs) } }
}

/// Records what the coordinator asks of the recording session.
@MainActor final class FakeRecordingSession: RecordingSession {
    struct Start: Equatable {
        var title: String?
        var source: SessionSource?
        var startedBy: MeetingStartedBy
        var event: CalendarEventInfo?
    }

    var state: SessionController.State = .idle
    private(set) var starts: [Start] = []
    private(set) var endCount = 0

    func startNewNote(
        title: String?, source: SessionSource?, startedBy: MeetingStartedBy, calendarEvent: CalendarEventInfo?
    ) async throws -> String? {
        starts.append(Start(title: title, source: source, startedBy: startedBy, event: calendarEvent))
        state = .recording(meetingID: "m1", startedAt: Date(), paused: false)
        return "m1"
    }

    func end() async {
        endCount += 1
        state = .idle
    }
}

@MainActor final class RecordedNotifier: PromptNotifier {
    struct Note: Equatable {
        var id: String
        var title: String
        var body: String
    }

    private(set) var prompts: [Note] = []
    private(set) var infos: [Note] = []
    private(set) var removed: [[String]] = []

    func activate(delegate: any UNUserNotificationCenterDelegate) {}
    func postPrompt(id: String, title: String, body: String) { prompts.append(Note(id: id, title: title, body: body)) }
    func postInfo(id: String, title: String, body: String) { infos.append(Note(id: id, title: title, body: body)) }
    func removeDelivered(ids: [String]) { removed.append(ids) }
}

/// Test time. With `autoAdvance`, `sleep` moves `now` forward and returns at once; without it,
/// sleepers park until `release()` advances `now` by each parked duration and resumes them.
final class VirtualClock: @unchecked Sendable {
    private struct State {
        var now: Date
        var autoAdvance = true
        var parked: [(Duration, CheckedContinuation<Void, Never>)] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        state = OSAllocatedUnfairLock(uncheckedState: State(now: now))
    }

    var now: Date {
        get { state.withLock(\.now) }
        set { state.withLock { $0.now = newValue } }
    }

    var autoAdvance: Bool {
        get { state.withLock(\.autoAdvance) }
        set { state.withLock { $0.autoAdvance = newValue } }
    }

    var parkedCount: Int { state.withLock { $0.parked.count } }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLockUnchecked { state -> Bool in
                guard state.autoAdvance else {
                    state.parked.append((duration, continuation))
                    return false
                }
                state.now += duration.timeInterval
                return true
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let parked = state.withLockUnchecked { state in
            let parked = state.parked
            state.parked.removeAll()
            for (duration, _) in parked { state.now += duration.timeInterval }
            return parked
        }
        for (_, continuation) in parked { continuation.resume() }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// Capture that records how it was started and writes no files.
final class FakeCapture: AudioCapturing, @unchecked Sendable {
    struct Started: Equatable {
        var scope: TapScope
        var directory: URL
        var micDeviceUID: String?
        var voiceProcessing: Bool
    }

    let chunks = AsyncStream<AudioChunk> { $0.finish() }
    let levels = AsyncStream<(mic: Float, system: Float)> { $0.finish() }
    let events = AsyncStream<CaptureEvent> { $0.finish() }
    private let state = OSAllocatedUnfairLock<(started: Started?, stopCount: Int)>(uncheckedState: (nil, 0))

    var started: Started? { state.withLockUnchecked(\.started) }
    var stopCount: Int { state.withLockUnchecked(\.stopCount) }

    func start(scope: TapScope, directory: URL, micDeviceUID: String?, voiceProcessing: Bool) async throws {
        state.withLockUnchecked {
            $0.started = Started(
                scope: scope, directory: directory, micDeviceUID: micDeviceUID, voiceProcessing: voiceProcessing)
        }
    }

    func pause() async {}
    func resume() async {}

    func stop() async -> CaptureSummary {
        let directory = state.withLockUnchecked { state -> URL in
            state.stopCount += 1
            return state.started?.directory ?? FileManager.default.temporaryDirectory
        }
        // The files are never written, so `SessionController.end()` records no audio rows.
        return CaptureSummary(
            micDuration: 1, systemDuration: 1, usedFallback: false,
            micFile: directory.appendingPathComponent(CaptureFiles.mic),
            systemFile: directory.appendingPathComponent(CaptureFiles.system))
    }
}

/// Yields its observations, then stays open until the consumer cancels; records the polled pid.
final class ScriptedSpeakerSource: SpeakerSource, @unchecked Sendable {
    static let bundleIDs = ["us.zoom.xos"]
    private let observations: [SpeakerObservation]
    private let observedPIDs = OSAllocatedUnfairLock<[pid_t]>(initialState: [])

    init(_ observations: [SpeakerObservation]) { self.observations = observations }

    var pids: [pid_t] { observedPIDs.withLock { $0 } }

    func observe(pid: pid_t, interval: TimeInterval) -> AsyncStream<SpeakerObservation> {
        observedPIDs.withLock { $0.append(pid) }
        let (stream, continuation) = AsyncStream.makeStream(of: SpeakerObservation.self)
        for observation in observations { continuation.yield(observation) }
        return stream
    }
}

/// Core Audio's process list with Zoom in a call: the main app, its helper, and an unrelated player.
func zoomProcesses(mainPID: pid_t = 500) -> [AudioProcessInfo] {
    [
        AudioProcessInfo(
            objectID: 1001, pid: mainPID, bundleID: "us.zoom.xos", name: "zoom.us", isRunningInput: true,
            isRunningOutput: true),
        AudioProcessInfo(
            objectID: 1002, pid: 501, bundleID: "us.zoom.xos.helper", name: "ZoomHelper", isRunningInput: false,
            isRunningOutput: true),
        AudioProcessInfo(
            objectID: 1003, pid: 700, bundleID: "com.spotify.client", name: "Spotify", isRunningInput: false,
            isRunningOutput: true),
    ]
}

let zoomSource = SessionSource(appName: "zoom.us", bundleID: "us.zoom.xos", pid: 500)

func zoomActivity(pid: pid_t = 500, running: Bool) -> InputActivity {
    InputActivity(
        bundleID: "us.zoom.xos", processBundleID: "us.zoom.xos", pid: pid, name: "zoom.us", isRunningInput: running)
}

/// A coordinator over fakes. The monitor it creates is published through `monitors`.
@MainActor func makeDetection(
    settings: AppSettings, session: FakeRecordingSession, clock: VirtualClock, notifier: RecordedNotifier,
    monitors: OSAllocatedUnfairLock<[FakeMonitor]>,
    calendar: @escaping @MainActor @Sendable (ClosedRange<TimeInterval>, Date) -> CalendarEventInfo? = { _, _ in nil }
) -> DetectionCoordinator {
    DetectionCoordinator(
        session: session, settings: settings,
        dependencies: DetectionDependencies(
            makeMonitor: { bundleIDs in
                let monitor = FakeMonitor(bundleIDs: bundleIDs)
                monitors.withLock { $0.append(monitor) }
                return monitor
            },
            calendarEvent: calendar,
            appName: { $0 == 500 ? "zoom.us" : nil },
            notifier: notifier,
            now: { clock.now },
            sleep: { await clock.sleep($0) }))
}

/// Polls `condition` every 10 ms for up to `timeout`; returns whether it became true.
@MainActor func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
