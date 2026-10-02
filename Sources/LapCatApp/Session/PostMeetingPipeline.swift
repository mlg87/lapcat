import Foundation
import LapCatAudio
import LapCatCore
import LapCatLLM
import LapCatSpeech
import os

/// Everything a pipeline run needs from settings, captured on the main actor when it starts.
struct PipelineConfig: Sendable {
    var speech: SpeechConfig
    var offlineOnly: Bool
    var retention: AudioRetention
    var meName: String
    var defaultTemplateID: String
    var autoExportFolder: URL?
    var router: LLMRouter
}

/// Post-meeting processing, one meeting at a time in FIFO order (plan §7.6).
///
/// Each step records itself in `meeting.processing_step` before it runs and is idempotent (it
/// replaces its own previous output), so a crash or a failed step resumes from that step.
/// Transcription and the final enhance are required: their failure puts the meeting in `error`
/// with "Retry processing". Diarization, the quick enhance, speaker suggestions and auto-export
/// are best-effort: their failure is logged and processing continues.
actor PostMeetingPipeline {
    enum Step: String, CaseIterable, Sendable {
        case quickEnhance = "quick_enhance"
        case finalSTTMic = "final_stt_mic"
        case finalSTTSystem = "final_stt_system"
        case diarize
        case nameMap = "name_map"
        case suggestSpeakers = "suggest_speakers"
        case echoDedup = "echo_dedup"
        case mergeLive = "merge_live"
        case reindex
        case enhance
        case autoExport = "auto_export"
        case retention

        var isBestEffort: Bool {
            switch self {
            case .quickEnhance, .diarize, .suggestSpeakers, .autoExport: true
            default: false
            }
        }

        var displayName: String {
            switch self {
            case .quickEnhance: "Quick notes"
            case .finalSTTMic: "Transcribing your audio"
            case .finalSTTSystem: "Transcribing meeting audio"
            case .diarize: "Separating speakers"
            case .nameMap: "Naming speakers"
            case .suggestSpeakers: "Suggesting names"
            case .echoDedup: "Removing echo"
            case .mergeLive: "Merging edits"
            case .reindex: "Indexing"
            case .enhance: "Enhancing notes"
            case .autoExport: "Exporting"
            case .retention: "Cleaning up audio"
            }
        }
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
    private let diarizer = FluidDiarizer()
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
                do {
                    try await perform(step, meetingID: meetingID, config: config)
                } catch where step.isBestEffort {
                    Self.logger.warning("\(step.rawValue, privacy: .public) skipped for \(meetingID, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            try await store.setMeetingStatus(meetingID: meetingID, status: .ready)
        } catch {
            Self.logger.error("processing \(meetingID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            try? await store.setMeetingStatus(meetingID: meetingID, status: .error, errorMessage: String(describing: error))
        }
        progressContinuation.yield(Progress(meetingID: meetingID, step: nil, fraction: 1))
    }

    private func perform(_ step: Step, meetingID: String, config: PipelineConfig) async throws {
        switch step {
        case .quickEnhance:
            // A first note from the live transcript, so something readable exists within a minute.
            try await enhanceIfPossible(meetingID: meetingID, config: config)
        case .finalSTTMic:
            try await finalTranscription(meetingID: meetingID, channel: .mic, step: step, config: config)
        case .finalSTTSystem:
            try await finalTranscription(meetingID: meetingID, channel: .system, step: step, config: config)
            // The final-pass model is only needed for these two steps; free it rather than keeping a
            // second whisper context resident next to the live one.
            await speech.unload(role: .final)
        case .diarize:
            try await diarize(meetingID: meetingID)
        case .nameMap:
            try await mapNames(meetingID: meetingID, config: config)
        case .suggestSpeakers:
            try await suggestSpeakers(meetingID: meetingID, config: config)
        case .echoDedup:
            let segments = try await store.segments(meetingID: meetingID, pass: .final)
            let ids = EchoDeduplicator.flag(
                micSegments: segments.filter { $0.channel == .mic },
                systemSegments: segments.filter { $0.channel == .system })
            try await store.setEchoDuplicates(meetingID: meetingID, micSegmentIDs: ids)
        case .mergeLive:
            try await store.mergeLiveIntoFinal(meetingID: meetingID)
        case .reindex:
            try await store.reindexFTS(meetingID: meetingID)
        case .enhance:
            try await enhanceIfPossible(meetingID: meetingID, config: config)
            try await store.reindexFTS(meetingID: meetingID)
        case .autoExport:
            if let folder = config.autoExportFolder {
                try await AutoExporter.export(meetingID: meetingID, folder: folder, store: store)
            }
        case .retention:
            if config.retention == .never {
                try? FileManager.default.removeItem(at: Paths.standard.audio(meetingID: meetingID))
                try await store.deleteAudioFiles(meetingID: meetingID)
            }
        }
    }

    // MARK: Steps

    private func enhanceIfPossible(meetingID: String, config: PipelineConfig) async throws {
        guard let meeting = try await store.meeting(id: meetingID) else { return }
        let enhancer = Enhancer(store: store, router: config.router)
        do {
            _ = try await enhancer.enhance(meetingID: meetingID, templateID: meeting.templateID ?? config.defaultTemplateID)
        } catch EnhancerError.nothingToEnhance {
            // No notes and no speech: nothing to write.
        }
    }

    private func audioFile(_ meetingID: String, _ channel: Channel) -> URL {
        Paths.standard.audio(meetingID: meetingID)
            .appendingPathComponent(CaptureFiles.fileName(for: channel == .mic ? .mic : .system))
    }

    private func finalTranscription(meetingID: String, channel: Channel, step: Step, config: PipelineConfig) async throws {
        let file = audioFile(meetingID, channel)
        // No recording for this channel (e.g. audio already deleted): keep whatever exists.
        guard FileManager.default.fileExists(atPath: file.path) else { return }
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

    /// Turns are cached next to the audio so `name_map` can resume without re-diarizing.
    private func diarizationCache(_ meetingID: String) -> URL {
        Paths.standard.audio(meetingID: meetingID).appendingPathComponent("diarization.json")
    }

    private struct CachedTurn: Codable { var startMs: Int; var endMs: Int; var cluster: String }

    private func diarize(meetingID: String) async throws {
        let cache = diarizationCache(meetingID)
        try? FileManager.default.removeItem(at: cache)
        let file = audioFile(meetingID, .system)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        // Diarization holds the decoded recording plus its models; free them once turns are cached.
        let turns: [DiarizedTurn]
        do {
            turns = try await diarizer.diarize(fileURL: file)
        } catch {
            await diarizer.unload()
            throw error
        }
        await diarizer.unload()
        let data = try JSONEncoder().encode(turns.map { CachedTurn(startMs: $0.startMs, endMs: $0.endMs, cluster: $0.cluster) })
        try data.write(to: cache, options: .atomic)
    }

    private func mapNames(meetingID: String, config: PipelineConfig) async throws {
        guard let meeting = try await store.meeting(id: meetingID) else { return }
        let turns: [DiarizedTurn] = ((try? Data(contentsOf: diarizationCache(meetingID)))
            .flatMap { try? JSONDecoder().decode([CachedTurn].self, from: $0) } ?? [])
            .map { DiarizedTurn(startMs: $0.startMs, endMs: $0.endMs, cluster: $0.cluster) }
        let segments = try await store.segments(meetingID: meetingID, pass: .final)
        let events = try await store.speakerEvents(meetingID: meetingID)
        let me = try await store.participants(meetingID: meetingID).first(where: \.isMe)?.displayName ?? config.meName
        let rows = NameMapper.assign(segments: segments, turns: turns, events: events, meName: me).map { assignment in
            let kind: SpeakerAssignmentRow.Kind = switch assignment.basis {
            case .me: .me
            case .speakerEvents, .clusterVote: assignment.participantName.map { .named($0) } ?? .unassigned
            case .cluster: assignment.participantName.map { .cluster($0) } ?? .unassigned
            case .unassigned: .unassigned
            }
            return SpeakerAssignmentRow(segmentID: assignment.segmentID, kind: kind, cluster: assignment.cluster)
        }
        let namedSource: ParticipantSource = meeting.sourceBundleID?.lowercased().hasPrefix("us.zoom") == true ? .zoomAX : .meetAX
        try await store.applySpeakerAssignments(meetingID: meetingID, rows: rows, namedSource: namedSource)
    }

    private func suggestSpeakers(meetingID: String, config: PipelineConfig) async throws {
        let participants = try await store.participants(meetingID: meetingID)
        let segments = try await store.segments(meetingID: meetingID, pass: .final)
        let assigned = Set(segments.compactMap(\.participantID))
        let clusters = participants.filter { $0.source == .cluster && assigned.contains($0.id ?? -1) }.map(\.displayName)
        let candidates = participants.filter {
            !$0.isMe && $0.source != .cluster && $0.source != .llmSuggested && !assigned.contains($0.id ?? -1)
        }.map(\.displayName)
        guard !clusters.isEmpty, !candidates.isEmpty else { return }
        let transcript = TranscriptFormatter.forLLM(segments: segments, participants: participants)
        let suggestions = try await SpeakerSuggester.suggest(
            router: config.router, transcript: transcript, clusters: clusters, candidates: candidates)
        for suggestion in suggestions {
            try await store.recordSpeakerSuggestion(meetingID: meetingID, cluster: suggestion.cluster, name: suggestion.name)
        }
    }
}
