import Foundation

/// One stretch of recognised speech, timed on the session clock (ms since recording start).
public struct TranscribedSegment: Sendable, Equatable {
    public var tStartMs: Int
    public var tEndMs: Int
    public var text: String
    public var confidence: Float?

    public init(tStartMs: Int, tEndMs: Int, text: String, confidence: Float? = nil) {
        self.tStartMs = tStartMs
        self.tEndMs = tEndMs
        self.text = text
        self.confidence = confidence
    }
}

/// A speech-to-text engine. Live callers pass ≤15 s utterances; the final pass hands over a whole file.
public protocol TranscriptionEngine: Sendable {
    /// `"whisper:ggml-small.en.bin"` | `"parakeet:v2"`.
    var id: String { get }
    /// Loads model weights. Idempotent.
    func load() async throws
    /// Transcribes 16 kHz mono Float32 samples; `offsetMs` is the session time of `samples16k[0]`.
    func transcribe(_ samples16k: [Float], offsetMs: Int) async throws -> [TranscribedSegment]
    /// Transcribes a recorded file (ADTS AAC, CAF, WAV, … — anything AVAudioFile reads) from time 0.
    func transcribeFile(_ url: URL, progress: @Sendable (Double) -> Void) async throws -> [TranscribedSegment]
    func unload() async
}

public enum SpeechError: Error, Equatable, CustomStringConvertible {
    case modelMissing(URL)
    case modelLoadFailed(String)
    case transcriptionFailed(String)
    case audioDecodeFailed(String)

    public var description: String {
        switch self {
        case .modelMissing(let url): "model file not found: \(url.path)"
        case .modelLoadFailed(let reason): "model load failed: \(reason)"
        case .transcriptionFailed(let reason): "transcription failed: \(reason)"
        case .audioDecodeFailed(let reason): "audio decode failed: \(reason)"
        }
    }
}
