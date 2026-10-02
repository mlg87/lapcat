import Foundation
import LapCatAudio
import LapCatCore
import LapCatSpeech
import os

/// Everything a pipeline run needs from settings, captured on the main actor when it starts.
struct PipelineConfig: Sendable {
    var speech: SpeechConfig
    var offlineOnly: Bool
    var retention: AudioRetention
}

/// Post-meeting processing, one meeting at a time in FIFO order.
///
/// Each step records itself in `meeting.processing_step` before it runs and is idempotent (it
/// replaces its own previous output), so a crash or a failed step resumes from that step.
actor PostMeetingPipeline {
    enum Step: String, CaseIterable, Sendable {
        case finalSTTMic = "final_stt_mic"
        case finalSTTSystem = "final_stt_system"
        case mergeLive = "merge_live"
        case reindex
        case retention
    }

    struct Progress: Sendable, Equatable {
        var meetingID: String
        var step: Step?
        var fraction: Double
    }

    nonisolated let progress: AsyncStream<Progress>
    private nonisolated let progressContinuation: AsyncStream<Progress>.Continuation
    private let store: Store
    private let speech: SpeechServices
    private let config: @Sendable () async -> PipelineConfig
    private var queue: [String] = []
    private var running = false
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "PostMeetingPipeline")

    init(store: Store, speech: SpeechServices, config: @escaping @Sendable () async -> PipelineConfig) {
        self.store = store
        self.speech = speech
        self.config = config
        (progress, progressContinuation) = AsyncStream.makeStream(of: Progress.self, bufferingPolicy: .bufferingNewest(32))
    }

    func enqueue(_ meetingID: String) {
        guard !queue.contains(meetingID) else { return }
        queue.append(meetingID)
        guard !running else { return }
        running = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let meetingID = queue.removeFirst()
            await run(meetingID)
        }
        running = false
    }

    private func run(_ meetingID: String) async {
        guard let meeting = try? await store.meeting(id: meetingID) else { return }
        let config = await config()
        let resumeFrom = meeting.processingStep.flatMap(Step.init(rawValue:))
        let steps = Step.allCases.drop { step in resumeFrom.map { $0 != step } ?? false }
        do {
            try await store.setMeetingStatus(meetingID: meetingID, status: .processing)
            for step in steps {
                try await store.setProcessingStep(meetingID: meetingID, step: step.rawValue)
                progressContinuation.yield(Progress(meetingID: meetingID, step: step, fraction: 0))
                try await perform(step, meetingID: meetingID, config: config)
            }
            try await store.setMeetingStatus(meetingID: meetingID, status: .ready)
            progressContinuation.yield(Progress(meetingID: meetingID, step: nil, fraction: 1))
        } catch {
            Self.logger.error("processing \(meetingID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            try? await store.setMeetingStatus(meetingID: meetingID, status: .error, errorMessage: String(describing: error))
            progressContinuation.yield(Progress(meetingID: meetingID, step: nil, fraction: 1))
        }
    }

    private func perform(_ step: Step, meetingID: String, config: PipelineConfig) async throws {
        switch step {
        case .finalSTTMic:
            try await finalTranscription(meetingID: meetingID, channel: .mic, step: step, config: config)
        case .finalSTTSystem:
            try await finalTranscription(meetingID: meetingID, channel: .system, step: step, config: config)
        case .mergeLive:
            try await store.mergeLiveIntoFinal(meetingID: meetingID)
        case .reindex:
            try await store.reindexFTS(meetingID: meetingID)
        case .retention:
            if config.retention == .never {
                try? FileManager.default.removeItem(at: Paths.standard.audio(meetingID: meetingID))
                try await store.deleteAudioFiles(meetingID: meetingID)
            }
        }
    }

    private func finalTranscription(meetingID: String, channel: Channel, step: Step, config: PipelineConfig) async throws {
        let file = Paths.standard.audio(meetingID: meetingID)
            .appendingPathComponent(CaptureFiles.fileName(for: channel == .mic ? .mic : .system))
        guard FileManager.default.fileExists(atPath: file.path) else {
            // No recording for this channel (e.g. audio already deleted): keep whatever exists.
            return
        }
        let spec = EngineSelector(config: config.speech).finalEngine()
        if let model = spec.requiredModelFile {
            try await ModelDownloader(modelsDirectory: config.speech.modelsDirectory, offlineOnly: config.offlineOnly)
                .download(model)
        }
        let engine = await speech.finalEngine(config: config.speech)
        try await engine.load()
        let continuation = progressContinuation
        let recognised = try await engine.transcribeFile(file) { fraction in
            continuation.yield(Progress(meetingID: meetingID, step: step, fraction: fraction))
        }
        let segments = recognised.compactMap { item -> Segment? in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, item.tEndMs > item.tStartMs else { return nil }
            return Segment(
                meetingID: meetingID, channel: channel, tStartMs: item.tStartMs, tEndMs: item.tEndMs,
                text: text, confidence: item.confidence.map(Double.init), pass: .final)
        }
        try await store.replaceFinalSegments(meetingID: meetingID, channel: channel, with: segments)
    }
}
