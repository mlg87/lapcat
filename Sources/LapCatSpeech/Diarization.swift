import FluidAudio
import Foundation

/// One diarized speaker turn on the system channel.
public struct DiarizedTurn: Sendable, Hashable {
    public var startMs: Int
    public var endMs: Int
    /// `"Speaker N"`, numbered by first appearance.
    public var cluster: String

    public init(startMs: Int, endMs: Int, cluster: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.cluster = cluster
    }
}

public protocol DiarizationEngine: Sendable {
    var id: String { get }
    func diarize(fileURL: URL) async throws -> [DiarizedTurn]
}

/// A raw diarizer turn before cluster labels are normalised.
public struct RawSpeakerTurn: Sendable, Hashable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var speakerID: String

    public init(startSeconds: Double, endSeconds: Double, speakerID: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speakerID = speakerID
    }
}

public enum DiarizationLabels {
    /// Sorts turns by start time and renames engine speaker ids to `Speaker 1…N` in order of first
    /// appearance, so labels are stable and readable regardless of the engine's internal ids.
    /// Turns with a non-positive duration are dropped.
    public static func normalize(_ turns: [RawSpeakerTurn]) -> [DiarizedTurn] {
        let ordered =
            turns
            .filter { $0.endSeconds > $0.startSeconds }
            .sorted { ($0.startSeconds, $0.endSeconds) < ($1.startSeconds, $1.endSeconds) }
        var labels: [String: String] = [:]
        return ordered.map { turn in
            let label: String
            if let existing = labels[turn.speakerID] {
                label = existing
            } else {
                label = "Speaker \(labels.count + 1)"
                labels[turn.speakerID] = label
            }
            return DiarizedTurn(
                startMs: Int((turn.startSeconds * 1000).rounded()),
                endMs: Int((turn.endSeconds * 1000).rounded()),
                cluster: label
            )
        }
    }
}

/// FluidAudio `OfflineDiarizerManager` (pyannote segmentation + WeSpeaker embeddings, Core ML).
/// Models are fetched by FluidAudio into its own cache on first use (blocked when
/// `SpeechServices.setOffline(true)`).
public actor FluidDiarizer: DiarizationEngine {
    /// `OfflineDiarizerManager` is a non-Sendable class; FluidAudio only writes its models during
    /// `prepareModels` and reads them afterwards, so the box crosses into nonisolated helpers.
    private final class ManagerBox: @unchecked Sendable {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
    }

    public nonisolated let id = "fluidaudio:offline"
    private var box: ManagerBox?

    public init() {}

    /// Downloads/compiles the models if needed. Idempotent.
    public func load() async throws {
        if box != nil { return }
        let box = ManagerBox()
        try await Self.prepare(box)
        self.box = box
    }

    public func diarize(fileURL: URL) async throws -> [DiarizedTurn] {
        try await load()
        guard let box else { return [] }
        // The recordings are ADTS AAC, which FluidAudio's file reader does not open; decode ourselves.
        let samples = try AudioDecoding.decode16kMono(fileURL)
        return DiarizationLabels.normalize(try await Self.process(box, samples: samples))
    }

    public func unload() {
        box = nil
    }

    private nonisolated static func prepare(_ box: ManagerBox) async throws {
        try await box.manager.prepareModels()
    }

    private nonisolated static func process(_ box: ManagerBox, samples: [Float]) async throws -> [RawSpeakerTurn] {
        let result = try await box.manager.process(audio: samples)
        return result.segments.map {
            RawSpeakerTurn(
                startSeconds: Double($0.startTimeSeconds), endSeconds: Double($0.endTimeSeconds),
                speakerID: $0.speakerId)
        }
    }
}
