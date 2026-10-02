import Foundation

/// Detects a process tap that has gone silent while its source is still playing (PRD FR-2.6/R7):
/// ≥ `threshold` of consecutive all-zero samples while the source reports running output.
struct TapHealthMonitor {
    static let sampleRate = 16_000
    let thresholdSamples: Int
    private var silentSamples = 0
    private var fired = false

    init(threshold: TimeInterval = 10) {
        thresholdSamples = Int(threshold * Double(Self.sampleRate))
    }

    /// Feeds one chunk. `sourceActive` is whether the tapped source reports running output.
    /// Returns `true` once per silent stretch, when it crosses the threshold.
    mutating func observe(_ samples: [Float], sourceActive: Bool) -> Bool {
        guard sourceActive, samples.allSatisfy({ $0 == 0 }) else {
            reset()
            return false
        }
        silentSamples += samples.count
        guard !fired, silentSamples >= thresholdSamples else { return false }
        fired = true
        return true
    }

    mutating func reset() {
        silentSamples = 0
        fired = false
    }
}
