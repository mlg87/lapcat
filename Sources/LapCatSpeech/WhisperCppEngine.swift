import Foundation
import os
import whisper

/// whisper.cpp in-process (Metal on arm64, CPU on x86_64). Runs on its own serial queue so the
/// multi-second blocking `whisper_full` call never occupies a Swift concurrency pool thread.
public actor WhisperCppEngine: TranscriptionEngine {
    public nonisolated let id: String
    private let modelURL: URL
    private let queue = DispatchSerialQueue(label: "com.lapcat.speech.whisper", qos: .userInitiated)
    private let native: WhisperNative
    private let logger = Logger(subsystem: "com.lapcat.app", category: "WhisperCppEngine")

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(modelURL: URL, language: String = "en") {
        self.modelURL = modelURL
        self.id = "whisper:\(modelURL.lastPathComponent)"
        self.native = WhisperNative(language: language)
    }

    public func load() throws {
        guard native.context == nil else { return }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw SpeechError.modelMissing(modelURL)
        }
        whisper_log_set({ _, _, _ in }, nil)
        var params = whisper_context_default_params()
        // Metal on Apple Silicon. Intel Macs run CPU-only: ggml compiles its Metal library from
        // source on Intel/AMD GPUs, which stalled model load for minutes in the stt-bench spike.
        #if arch(arm64)
        params.use_gpu = true
        #else
        params.use_gpu = false
        #endif
        guard let ctx = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw SpeechError.modelLoadFailed("whisper_init_from_file_with_params returned NULL for \(modelURL.lastPathComponent)")
        }
        native.context = ctx
        logger.info("loaded \(self.modelURL.lastPathComponent, privacy: .public)")
    }

    public func transcribe(_ samples16k: [Float], offsetMs: Int) throws -> [TranscribedSegment] {
        try load()
        return WhisperSegmentFilter.segments(from: try decode(samples16k), offsetMs: offsetMs)
    }

    public func transcribeFile(_ url: URL, progress: @Sendable (Double) -> Void) throws -> [TranscribedSegment] {
        try load()
        let reader = try AudioFileReader(url: url)
        let estimated = max(reader.estimatedFrames, 1)
        var result: [TranscribedSegment] = []
        // `buffer` holds undecoded audio from sample `bufferStart`; one sample beyond a window tells
        // whether the current window is the last.
        var buffer: [Float] = []
        var bufferStart = 0
        while true {
            buffer += try reader.read(frames: WhisperWindowing.windowSamples + 1 - buffer.count)
            guard !buffer.isEmpty else { break }
            let isLast = buffer.count <= WhisperWindowing.windowSamples
            let window = Array(buffer.prefix(WhisperWindowing.windowSamples))
            let startMs = bufferStart / 16
            let endMs = (bufferStart + window.count) / 16
            let segments = WhisperSegmentFilter.segments(from: try decode(window), offsetMs: startMs)
            let commit = WhisperWindowing.commit(segments, windowStartMs: startMs, windowEndMs: endMs, isLast: isLast)
            result += commit.kept
            progress(min(1, Double(bufferStart + window.count) / Double(estimated)))
            if isLast { break }
            let advance = min(window.count, max(16, (commit.nextStartMs - startMs) * 16))
            buffer.removeFirst(advance)
            bufferStart += advance
        }
        progress(1)
        return result
    }

    public func unload() {
        native.free()
    }

    private func decode(_ samples: [Float]) throws -> [WhisperRawSegment] {
        guard let context = native.context else { throw SpeechError.modelLoadFailed("whisper context not loaded") }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.language = UnsafePointer(native.language)
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_context = true
        params.single_segment = false
        params.suppress_blank = true
        params.token_timestamps = false
        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard status == 0 else { throw SpeechError.transcriptionFailed("whisper_full returned \(status)") }
        return (0..<whisper_full_n_segments(context)).map { index in
            WhisperRawSegment(
                t0Centiseconds: whisper_full_get_segment_t0(context, index),
                t1Centiseconds: whisper_full_get_segment_t1(context, index),
                text: whisper_full_get_segment_text(context, index).map { String(cString: $0) } ?? ""
            )
        }
    }
}

/// Owns whisper's C allocations; confined to the engine actor, freed when the engine goes away.
private final class WhisperNative {
    /// `strdup`'d language code, alive for the engine's lifetime because the params point at it.
    let language: UnsafeMutablePointer<CChar>
    var context: OpaquePointer?

    init(language: String) {
        self.language = strdup(language)
    }

    func free() {
        if let context { whisper_free(context) }
        context = nil
    }

    deinit {
        free()
        Foundation.free(language)
    }
}
