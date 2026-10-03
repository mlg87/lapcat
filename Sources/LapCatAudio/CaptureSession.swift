import AVFoundation
import CoreAudio
import Foundation
import os

/// Records one meeting: the microphone ("Me") and the meeting app's output ("Them") as two
/// 16 kHz mono channels on one clock, written to `<directory>/mic.aac` and `them.aac` and
/// streamed as `chunks`. One instance per meeting; `start` once, `stop` once.
///
/// The system channel uses a process tap. A tap that goes silent while its source plays is
/// rebuilt once; if that recurs within 60 s, or the tap cannot be created, ScreenCaptureKit
/// audio takes over. With neither available the session records the microphone only and emits
/// `.error(.systemAudioUnavailable)`.
///
/// `chunks` is unbounded: consumers must drain it.
public actor CaptureSession {
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "CaptureSession")
    private static let fallbackWindow: Duration = .seconds(60)

    public nonisolated let chunks: AsyncStream<AudioChunk>
    public nonisolated let levels: AsyncStream<(mic: Float, system: Float)>
    public nonisolated let events: AsyncStream<CaptureEvent>

    private nonisolated let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private nonisolated let levelContinuation: AsyncStream<(mic: Float, system: Float)>.Continuation
    private nonisolated let eventContinuation: AsyncStream<CaptureEvent>.Continuation
    private nonisolated let latestLevels = OSAllocatedUnfairLock(initialState: (mic: Float(0), system: Float(0)))

    private enum SystemSource {
        case none
        case tap(ProcessTap)
        case screenCapture(SCKAudioCapture)
    }

    private enum Phase { case idle, running, stopped }

    private var phase = Phase.idle
    private var scope = TapScope.systemExcludingSelf
    private var mic: MicCapture?
    private var micPipeline: ChannelPipeline?
    private var systemPipeline: ChannelPipeline?
    private var systemSource = SystemSource.none
    private var usedFallback = false
    private var tapSucceededReported = false
    private var lastSilenceRebuild: ContinuousClock.Instant?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "com.lapcat.audio.device-listener")
    private var clockTask: Task<Void, Never>?

    private var activeSince: ContinuousClock.Instant?
    private var activeBefore: Duration = .zero

    public init() {
        (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        (levels, levelContinuation) = AsyncStream.makeStream(
            of: (mic: Float, system: Float).self, bufferingPolicy: .bufferingNewest(8)
        )
        (events, eventContinuation) = AsyncStream.makeStream(of: CaptureEvent.self, bufferingPolicy: .unbounded)
    }

    /// Starts both channels. Throws when the microphone or the output files cannot be opened;
    /// system-audio failures degrade (see type docs) and are reported on `events`.
    public func start(scope: TapScope, directory: URL, micDeviceUID: String?, voiceProcessing: Bool) async throws {
        guard phase == .idle else { throw AudioCaptureError.alreadyStarted }
        phase = .running
        self.scope = scope
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            phase = .stopped
            throw AudioCaptureError.fileWrite(error.localizedDescription)
        }

        let micPipeline: ChannelPipeline
        let systemPipeline: ChannelPipeline
        do {
            micPipeline = try ChannelPipeline(
                channel: .mic, directory: directory, mixdown: .firstChannel, callbacks: callbacks(for: .mic)
            )
            systemPipeline = try ChannelPipeline(
                channel: .system, directory: directory, mixdown: .average, callbacks: callbacks(for: .system)
            )
        } catch {
            phase = .stopped
            throw error
        }
        self.micPipeline = micPipeline
        self.systemPipeline = systemPipeline

        // Mic first: it registers this process with the HAL, so the global tap can exclude it.
        let mic = MicCapture(
            deviceUID: micDeviceUID,
            voiceProcessing: voiceProcessing,
            onBuffer: { micPipeline.ingest($0) },
            onConfigurationChange: { [weak self] in
                guard let self else { return }
                Task { await self.micConfigurationChanged() }
            }
        )
        do {
            let format = try mic.start()
            self.mic = mic
            eventContinuation.yield(.sourceStarted(.mic, format: Self.describe(format)))
        } catch {
            _ = micPipeline.finish()
            _ = systemPipeline.finish()
            phase = .stopped
            finishStreams()
            throw error
        }

        activeSince = .now
        do {
            try startTap()
        } catch {
            eventContinuation.yield(.error(error))
            await engageFallback()
        }
        installOutputDeviceListener()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.alignChannels()
            }
        }
    }

    public func pause() {
        guard phase == .running, let since = activeSince else { return }
        activeBefore += ContinuousClock.now - since
        activeSince = nil
        micPipeline?.setPaused(true)
        systemPipeline?.setPaused(true)
        levelContinuation.yield((mic: 0, system: 0))
    }

    public func resume() {
        guard phase == .running, activeSince == nil else { return }
        activeSince = .now
        micPipeline?.setPaused(false)
        systemPipeline?.setPaused(false)
    }

    /// Stops capture and closes both files. Safe to call more than once.
    public func stop() async -> CaptureSummary {
        if phase == .running {
            phase = .stopped
            clockTask?.cancel()
            clockTask = nil
            removeOutputDeviceListener()
            mic?.stop()
            mic = nil
            await stopSystemSource()
            alignChannels()
            if let since = activeSince { activeBefore += ContinuousClock.now - since }
            activeSince = nil
        }
        let micSamples = micPipeline?.finish() ?? 0
        let systemSamples = systemPipeline?.finish() ?? 0
        finishStreams()
        let rate = Double(ChannelPipeline.sampleRate)
        return CaptureSummary(
            micDuration: Double(micSamples) / rate,
            systemDuration: Double(systemSamples) / rate,
            usedFallback: usedFallback,
            micFile: micPipeline?.fileURL ?? URL(fileURLWithPath: CaptureFiles.mic),
            systemFile: systemPipeline?.fileURL ?? URL(fileURLWithPath: CaptureFiles.system)
        )
    }

    // MARK: - Pipeline callbacks

    private func callbacks(for channel: AudioChannel) -> ChannelPipeline.Callbacks {
        let chunks = chunkContinuation
        let levels = levelContinuation
        let events = eventContinuation
        let latest = latestLevels
        return ChannelPipeline.Callbacks(
            chunk: { chunks.yield($0) },
            level: { level in
                let pair = latest.withLock { state in
                    if channel == .mic { state.mic = level } else { state.system = level }
                    return state
                }
                levels.yield(pair)
            },
            signal: { [weak self] in
                guard channel == .system, let self else { return }
                Task { await self.systemSignalSeen() }
            },
            silentWhileActive: { [weak self] in
                guard let self else { return }
                Task { await self.systemTapSilent() }
            },
            error: { events.yield(.error($0)) }
        )
    }

    private func finishStreams() {
        chunkContinuation.finish()
        levelContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: - System source management

    private func startTap() throws(AudioCaptureError) {
        guard let pipeline = systemPipeline else { return }
        let tap = try ProcessTap(scope: scope)
        do { try tap.start { pipeline.ingest($0) } } catch {
            tap.invalidate()
            throw error
        }
        systemSource = .tap(tap)
        pipeline.sourceChanged()
        let scope = scope
        Self.logger.info("system tap started: \(Self.describe(scope), privacy: .public)")
        pipeline.monitorHealth {
            switch scope {
            case .app(let objectIDs, _): objectIDs.contains(where: AudioProcessRegistry.isRunningOutput)
            case .systemExcludingSelf: AudioProcessRegistry.anyOtherProcessRunningOutput()
            }
        }
        eventContinuation.yield(.sourceStarted(.system, format: Self.describe(tap.format)))
    }

    private func stopSystemSource() async {
        switch systemSource {
        case .none: break
        case .tap(let tap): tap.invalidate()
        case .screenCapture(let capture): await capture.stop()
        }
        systemSource = .none
    }

    private func rebuildTap() {
        guard phase == .running else { return }
        if case .tap(let old) = systemSource { old.invalidate() }
        systemSource = .none
        do {
            try startTap()
            eventContinuation.yield(.tapRebuilt)
        } catch {
            eventContinuation.yield(.error(error))
            Task { await engageFallback() }
        }
    }

    /// Switches the system channel to ScreenCaptureKit. The tap (if any) keeps running until
    /// ScreenCaptureKit is up, so a failed switch loses nothing.
    private func engageFallback() async {
        guard phase == .running, let pipeline = systemPipeline else { return }
        if case .screenCapture = systemSource { return }
        let pid: pid_t? =
            switch scope {
            case .app(_, let appPID): appPID
            case .systemExcludingSelf: nil
            }
        let capture = SCKAudioCapture(pid: pid) { pipeline.ingest($0) }
        do {
            try await capture.start()
        } catch {
            eventContinuation.yield(.error(error))
            if case .none = systemSource { eventContinuation.yield(.error(.systemAudioUnavailable)) }
            return
        }
        guard phase == .running else {
            await capture.stop()
            return
        }
        if case .tap(let tap) = systemSource { tap.invalidate() }
        systemSource = .screenCapture(capture)
        usedFallback = true
        pipeline.sourceChanged()
        eventContinuation.yield(.sourceStarted(.system, format: "ScreenCaptureKit 16000 Hz mono"))
        eventContinuation.yield(.fallbackEngaged)
    }

    private func systemTapSilent() async {
        guard phase == .running, case .tap = systemSource else { return }
        if let last = lastSilenceRebuild, ContinuousClock.now - last < Self.fallbackWindow {
            Self.logger.warning("tap silent again within 60 s of a rebuild; engaging fallback")
            await engageFallback()
        } else {
            Self.logger.warning("tap silent while source plays; rebuilding")
            lastSilenceRebuild = .now
            rebuildTap()
        }
    }

    private func systemSignalSeen() {
        guard !tapSucceededReported, case .tap = systemSource else { return }
        tapSucceededReported = true
        eventContinuation.yield(.systemAudioTapSucceeded)
    }

    private func micConfigurationChanged() {
        guard phase == .running else { return }
        micPipeline?.sourceChanged()
        eventContinuation.yield(.deviceChanged(.mic))
    }

    // MARK: - Default output device

    private func installOutputDeviceListener() {
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.outputDeviceChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(CoreAudioProperty.system, &address, listenerQueue, block) == noErr {
            outputListener = block
        }
    }

    private func removeOutputDeviceListener() {
        guard let outputListener else { return }
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(CoreAudioProperty.system, &address, listenerQueue, outputListener)
        self.outputListener = nil
    }

    /// The aggregate device wraps the old output device: rebuild tap and aggregate together.
    private func outputDeviceChanged() {
        guard phase == .running else { return }
        eventContinuation.yield(.deviceChanged(.system))
        if case .tap = systemSource { rebuildTap() }
    }

    // MARK: - Clock

    private var activeSamples: Int {
        var active = activeBefore
        if let since = activeSince { active += ContinuousClock.now - since }
        let seconds = Double(active.components.seconds) + Double(active.components.attoseconds) / 1e18
        return Int(seconds * Double(ChannelPipeline.sampleRate))
    }

    private func alignChannels() {
        guard activeSince != nil else { return }
        let target = activeSamples
        micPipeline?.padSilence(upTo: target)
        systemPipeline?.padSilence(upTo: target)
    }

    /// `app pid 11771: Arc pid 11771 out=0, Browser Helper pid 73835 out=1` — which processes the tap mixes.
    private static func describe(_ scope: TapScope) -> String {
        switch scope {
        case .systemExcludingSelf:
            return "all system audio except LapCat"
        case .app(let objectIDs, let appPID):
            let processes = objectIDs.map { id in
                guard let info = AudioProcessRegistry.info(forObjectID: id) else { return "object \(id) gone" }
                return "\(info.name) pid \(info.pid) out=\(info.isRunningOutput ? 1 : 0)"
            }
            return "app pid \(appPID.map(String.init) ?? "none"): \(processes.joined(separator: ", "))"
        }
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        let asbd = format.streamDescription.pointee
        let kind =
            switch format.commonFormat {
            case .pcmFormatFloat32: "Float32"
            case .pcmFormatFloat64: "Float64"
            case .pcmFormatInt16: "Int16"
            case .pcmFormatInt32: "Int32"
            default: "format \(asbd.mFormatID)"
            }
        return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(kind), "
            + (format.isInterleaved ? "interleaved" : "non-interleaved")
    }
}
