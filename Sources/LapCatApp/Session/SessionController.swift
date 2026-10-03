import Foundation
import LapCatAudio
import LapCatCore
import LapCatSpeech
import Observation
import os

/// Where a recording was started from: the detected meeting app, if any.
struct SessionSource: Sendable {
    var appName: String
    var bundleID: String?
    var pid: pid_t?
}

/// Runs one recording at a time: meeting row, dual-channel capture, live transcription,
/// and hand-off to post-meeting processing when it ends.
@Observable @MainActor
final class SessionController {
    enum State: Equatable {
        case idle
        case starting
        case recording(meetingID: String, startedAt: Date, paused: Bool)
        case ending(meetingID: String)
    }

    private(set) var state: State = .idle
    private(set) var levels: (mic: Float, system: Float) = (0, 0)
    /// Latest problem worth showing (system audio unavailable, live transcript lagging, …).
    private(set) var warning: String?
    /// Advances once a second while recording, so views showing the elapsed time refresh.
    private(set) var clock = Date()

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let speech: SpeechServices
    /// Called with the meeting id once the session's rows are written; the post-meeting pipeline.
    @ObservationIgnored var onEnded: (@MainActor (String) -> Void)?
    @ObservationIgnored private var capture: CaptureSession?
    @ObservationIgnored private var transcribers: [Channel: LiveTranscriber] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pausedTotal: TimeInterval = 0
    @ObservationIgnored private var pausedSince: Date?
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "SessionController")

    init(store: Store, settings: AppSettings, speech: SpeechServices) {
        self.store = store
        self.settings = settings
        self.speech = speech
    }

    var meetingID: String? {
        switch state {
        case .recording(let id, _, _), .ending(let id): id
        case .idle, .starting: nil
        }
    }

    var isPaused: Bool { if case .recording(_, _, true) = state { true } else { false } }

    /// Recording time excluding pauses.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard case .recording(_, let startedAt, _) = state else { return 0 }
        let pausedNow = pausedSince.map { now.timeIntervalSince($0) } ?? 0
        return max(0, now.timeIntervalSince(startedAt) - pausedTotal - pausedNow)
    }

    var speechConfig: SpeechConfig {
        SpeechConfig(
            engine: SpeechConfig.EngineChoice(rawValue: settings.sttEngine) ?? .auto,
            whisperLiveModel: settings.sttWhisperLiveModel,
            whisperFinalModel: settings.sttWhisperFinalModel,
            parakeetVersion: settings.sttParakeetVersion,
            modelsDirectory: Paths.standard.models)
    }

    /// Starts a new recording. Returns the meeting id, or nil when one is already running.
    @discardableResult
    func startNewNote(
        title: String? = nil, source: SessionSource? = nil, startedBy: MeetingStartedBy = .manual,
        calendarEvent: CalendarEventInfo? = nil
    ) async throws -> String? {
        guard state == .idle else { return nil }
        state = .starting
        do {
            return try await start(title: title, source: source, startedBy: startedBy, calendarEvent: calendarEvent)
        } catch {
            for task in tasks { task.cancel() }
            tasks.removeAll()
            transcribers.removeAll()
            if let capture { _ = await capture.stop() }
            capture = nil
            if let id = startingMeetingID {
                try? await store.setMeetingStatus(
                    meetingID: id, status: .error, errorMessage: "Recording failed to start: \(error)")
            }
            startingMeetingID = nil
            state = .idle
            throw error
        }
    }

    @ObservationIgnored private var startingMeetingID: String?

    private func start(
        title: String?, source: SessionSource?, startedBy: MeetingStartedBy, calendarEvent: CalendarEventInfo?
    ) async throws -> String {
        let now = Date()
        let meeting = try await store.createMeeting(
            title: title ?? MeetingTitle.default(for: now), startedBy: startedBy,
            sourceApp: source?.appName ?? "other", bundleID: source?.bundleID, pid: source?.pid, now: now)
        startingMeetingID = meeting.id
        try await store.upsertParticipant(
            meetingID: meeting.id, name: settings.userDisplayName, source: .manual, isMe: true)
        // Title and attendees from the overlapping calendar event (nil without Calendar access).
        if let event = calendarEvent ?? CalendarService().currentOrUpcomingEvent(now: now) {
            try await store.applyCalendarEvent(event, toMeeting: meeting.id, now: now)
        }
        let directory = Paths.standard.audio(meetingID: meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let capture = CaptureSession()
        self.capture = capture
        let hypothesis: TimeInterval? = settings.sttLiveHypothesis ? 2.0 : nil
        let config = speechConfig
        let speech = speech
        let offline = settings.llmOfflineOnly
        for channel in [Channel.mic, .system] {
            transcribers[channel] = LiveTranscriber(
                meetingID: meeting.id, channel: channel, store: store, hypothesisInterval: hypothesis,
                makeEngine: {
                    let spec = EngineSelector(config: config).liveEngine()
                    if let file = spec.requiredModelFile {
                        try await ModelDownloader(modelsDirectory: config.modelsDirectory, offlineOnly: offline)
                            .download(file)
                    }
                    return await speech.liveEngine(config: config)
                })
        }
        observe(capture)
        tasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.clock = Date()
                }
            })

        try await capture.start(
            scope: tapScope(for: source), directory: directory,
            micDeviceUID: settings.audioInputDeviceUID, voiceProcessing: settings.audioVoiceProcessing)
        pausedTotal = 0
        pausedSince = nil
        warning = nil
        state = .recording(meetingID: meeting.id, startedAt: now, paused: false)
        startingMeetingID = nil
        startSpeakerRecorder(meetingID: meeting.id, source: source)
        Self.logger.notice("recording \(meeting.id, privacy: .public)")
        return meeting.id
    }

    private func startSpeakerRecorder(meetingID: String, source: SessionSource?) {
        let elapsed: @Sendable () async -> Int = { [weak self] in
            await MainActor.run { Int((self?.elapsed() ?? 0) * 1000) }
        }
        guard
            let (recorder, adapter, pid) = SpeakerEventRecorder.make(
                store: store, meetingID: meetingID, bundleID: source?.bundleID, pid: source?.pid,
                settings: settings, elapsedMs: elapsed)
        else { return }
        speakerRecorder = recorder
        Task { await recorder.start(adapter: adapter, pid: pid) }
    }

    @ObservationIgnored private var speakerRecorder: SpeakerEventRecorder?

    private func tapScope(for source: SessionSource?) -> TapScope {
        guard settings.audioTapScope == "app", let source else { return .systemExcludingSelf }
        // By bundle first: it prefers the instance producing output, whereas the detected pid is
        // often an input-only helper (a browser's audio-capture process).
        if let bundleID = source.bundleID, let id = AudioProcessRegistry.objectID(forBundleID: bundleID) {
            return .process(id)
        }
        if let pid = source.pid, let id = AudioProcessRegistry.objectID(forPID: pid) { return .process(id) }
        return .systemExcludingSelf
    }

    private func observe(_ capture: CaptureSession) {
        let transcribers = transcribers
        tasks.append(
            Task.detached {
                for await chunk in capture.chunks {
                    let channel: Channel = chunk.channel == .mic ? .mic : .system
                    await transcribers[channel]?.append(chunk.samples, tStartMs: chunk.tStartMs)
                }
            })
        tasks.append(
            Task { [weak self] in
                for await level in capture.levels { self?.levels = level }
            })
        tasks.append(
            Task { [weak self] in
                for await event in capture.events { self?.handle(event) }
            })
        for transcriber in transcribers.values {
            tasks.append(
                Task { [weak self] in
                    for await event in transcriber.events { self?.handle(event) }
                })
        }
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .systemAudioTapSucceeded:
            Permissions.markGranted(.systemAudio)
        case .fallbackEngaged:
            warning = "System audio tap failed; using screen-recording capture."
        case .error(.systemAudioUnavailable):
            warning = "System audio unavailable — recording your microphone only."
        case .error(.systemAudioPermissionMissing):
            warning = "LapCat lacks System Audio Recording permission — open Permissions to grant it."
        case .error(let error):
            Self.logger.error("capture: \(error.description, privacy: .public)")
        case .sourceStarted, .deviceChanged, .tapRebuilt:
            Self.logger.info("capture event: \(String(describing: event), privacy: .public)")
        }
    }

    private func handle(_ event: LiveTranscriber.Event) {
        switch event {
        case .laggingBehind(_, let seconds):
            warning = "Transcript running \(Int(seconds.rounded())) s behind."
        case .caughtUp:
            if warning?.hasPrefix("Transcript running") == true { warning = nil }
        case .unavailable(_, let reason):
            warning = "Live transcript unavailable: \(reason)"
        }
    }

    func togglePause() async {
        guard case .recording(let id, let startedAt, let paused) = state, let capture else { return }
        if paused {
            await capture.resume()
            if let since = pausedSince { pausedTotal += Date().timeIntervalSince(since) }
            pausedSince = nil
        } else {
            await capture.pause()
            pausedSince = Date()
        }
        state = .recording(meetingID: id, startedAt: startedAt, paused: !paused)
    }

    /// Stops capture, drains live transcription, records the audio files, and hands the
    /// meeting to post-meeting processing.
    func end() async {
        guard case .recording(let meetingID, _, _) = state, let capture else { return }
        // Close speaker events while the session clock is still running.
        await speakerRecorder?.stop()
        speakerRecorder = nil
        state = .ending(meetingID: meetingID)
        let summary = await capture.stop()
        // The final pass re-transcribes the recording, so queued live work is dropped.
        await withTaskGroup(of: Void.self) { group in
            for transcriber in transcribers.values {
                group.addTask { await transcriber.finish(discardBacklog: true) }
            }
        }
        for task in tasks { task.cancel() }
        tasks.removeAll()
        transcribers.removeAll()
        self.capture = nil
        levels = (0, 0)

        do {
            let now = Date()
            for (channel, url, duration) in [
                (Channel.mic, summary.micFile, summary.micDuration),
                (Channel.system, summary.systemFile, summary.systemDuration),
            ] where FileManager.default.fileExists(atPath: url.path) {
                try await store.saveAudioFile(
                    AudioFile(
                        meetingID: meetingID, channel: channel, path: url.path,
                        codec: CaptureFiles.codec, durationMs: Int(duration * 1000)))
            }
            if var meeting = try await store.meeting(id: meetingID) {
                meeting.endedAt = now
                meeting.status = .processing
                meeting.processingStep = nil
                meeting.audioRetainedUntil = settings.audioRetention.retainedUntil(from: now)
                try await store.updateMeeting(meeting, now: now)
            }
        } catch {
            Self.logger.error(
                "finishing \(meetingID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        state = .idle
        onEnded?(meetingID)
    }
}
