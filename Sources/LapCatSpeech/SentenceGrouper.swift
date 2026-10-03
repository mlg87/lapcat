import Foundation

/// A recognised word with times in seconds relative to the decoded buffer.
struct TimedWord: Sendable, Equatable {
    var word: String
    var startTime: TimeInterval
    var endTime: TimeInterval
}

/// Groups Parakeet word timings into sentence segments.
enum SentenceGrouper {
    static let maxGapMs = 800

    /// Splits after a word ending in `.`, `?` or `!`, and before a word that starts more than 800 ms
    /// after the previous word ended. Times become session ms via `offsetMs`.
    static func group(_ words: [TimedWord], offsetMs: Int, confidence: Float?) -> [TranscribedSegment] {
        var segments: [TranscribedSegment] = []
        var current: [TimedWord] = []

        func close() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(
                TranscribedSegment(
                    tStartMs: offsetMs + ms(first.startTime),
                    tEndMs: offsetMs + ms(last.endTime),
                    text: current.map(\.word).joined(separator: " "),
                    confidence: confidence
                ))
            current.removeAll()
        }

        for word in words {
            if let previous = current.last, ms(word.startTime) - ms(previous.endTime) > maxGapMs {
                close()
            }
            current.append(word)
            if let terminal = word.word.last, ".?!".contains(terminal) {
                close()
            }
        }
        close()
        return segments
    }

    /// Used when the engine reports no token timings: one segment spanning the whole chunk.
    static func fallback(text: String, offsetMs: Int, sampleCount: Int, confidence: Float?) -> [TranscribedSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [
            TranscribedSegment(
                tStartMs: offsetMs, tEndMs: offsetMs + sampleCount / 16, text: trimmed, confidence: confidence)
        ]
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
}
