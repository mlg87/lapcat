import Foundation

/// Frame-level energy voice-activity classifier with an adaptive noise floor.
///
/// A 20 ms frame is speech when its energy exceeds the noise floor by `marginDB`. The floor
/// follows non-speech frames quickly (and drops immediately to quieter ones) but rises only
/// slowly during speech, so long speech is not absorbed into the floor while a lasting change in
/// background noise still is.
public struct EnergyVAD: Sendable {
    public static let sampleRate = 16_000
    public static let frameSamples = 320  // 20 ms

    public var marginDB: Float
    public private(set) var noiseFloorDB: Float
    /// The floor never drops below this, so digital silence does not make faint noise "speech".
    public let minimumFloorDB: Float

    private static let trackRate: Float = 0.05
    private static let speechRiseDBPerFrame: Float = 0.01  // 0.5 dB/s

    public init(marginDB: Float = 10, initialFloorDB: Float = -60, minimumFloorDB: Float = -70) {
        self.marginDB = marginDB
        noiseFloorDB = max(initialFloorDB, minimumFloorDB)
        self.minimumFloorDB = minimumFloorDB
    }

    public static func energyDB(_ frame: UnsafeBufferPointer<Float>) -> Float {
        guard !frame.isEmpty else { return -120 }
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        return 10 * log10(sum / Float(frame.count) + 1e-12)
    }

    /// Classifies one frame and updates the noise floor.
    public mutating func isSpeech(_ frame: UnsafeBufferPointer<Float>) -> Bool {
        let energy = Self.energyDB(frame)
        let speech = energy > noiseFloorDB + marginDB
        if speech {
            noiseFloorDB += Self.speechRiseDBPerFrame
        } else if energy < noiseFloorDB {
            noiseFloorDB = energy
        } else {
            noiseFloorDB += Self.trackRate * (energy - noiseFloorDB)
        }
        noiseFloorDB = max(noiseFloorDB, minimumFloorDB)
        return speech
    }
}
