import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT via FluidAudio (Core ML). Models are fetched by FluidAudio into its own cache;
/// `SpeechServices.setOffline(true)` makes that fetch fail instead of touching the network.
public actor ParakeetEngine: TranscriptionEngine {
    public nonisolated let id: String
    private let version: AsrModelVersion
    private var loading: Task<AsrManager, Error>?

    /// `version`: `"v2"` (English) or `"v3"` (multilingual).
    public init(version: String) {
        self.version = version == "v3" ? .v3 : .v2
        self.id = "parakeet:\(version == "v3" ? "v3" : "v2")"
    }

    public func load() async throws {
        _ = try await manager()
    }

    public func transcribe(_ samples16k: [Float], offsetMs: Int) async throws -> [TranscribedSegment] {
        let asr = try await manager()
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        var samples = samples16k
        if samples.count < minimum {
            samples += [Float](repeating: 0, count: minimum - samples.count)
        }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await asr.transcribe(samples, decoderState: &state)
        } catch {
            throw SpeechError.transcriptionFailed("parakeet: \(error)")
        }
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(word: $0.word, startTime: $0.startTime, endTime: $0.endTime)
        }
        guard result.tokenTimings != nil, !words.isEmpty else {
            return SentenceGrouper.fallback(
                text: result.text, offsetMs: offsetMs, sampleCount: samples16k.count, confidence: result.confidence
            )
        }
        return SentenceGrouper.group(words, offsetMs: offsetMs, confidence: result.confidence)
    }

    public func transcribeFile(_ url: URL, progress: @Sendable (Double) -> Void) async throws -> [TranscribedSegment] {
        progress(0)
        let samples = try AudioFileReader(url: url).readAll()
        guard !samples.isEmpty else {
            progress(1)
            return []
        }
        // FluidAudio chunks long-form audio internally.
        let segments = try await transcribe(samples, offsetMs: 0)
        progress(1)
        return segments
    }

    public func unload() async {
        guard let loading else { return }
        self.loading = nil
        if let asr = try? await loading.value {
            await asr.cleanup()
        }
    }

    private func manager() async throws -> AsrManager {
        if let loading { return try await loading.value }
        let version = self.version
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            return asr
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw SpeechError.modelLoadFailed("parakeet \(id): \(error)")
        }
    }
}
