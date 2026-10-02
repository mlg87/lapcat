import Foundation

/// A segment exactly as whisper.cpp reports it: times in centiseconds relative to the decoded buffer.
struct WhisperRawSegment: Sendable, Equatable {
    var t0Centiseconds: Int64
    var t1Centiseconds: Int64
    var text: String
}

enum WhisperSegmentFilter {
    /// Whisper's non-speech annotations (`^\[.*\]$|^\(.*\)$`): `[BLANK_AUDIO]`, `[Music]`, `(music)`, …
    static func isNonSpeech(_ text: String) -> Bool {
        (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")"))
    }

    /// Converts centiseconds to ms, shifts by `offsetMs`, trims, and drops empty / non-speech segments.
    static func segments(from raw: [WhisperRawSegment], offsetMs: Int) -> [TranscribedSegment] {
        raw.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNonSpeech(text) else { return nil }
            return TranscribedSegment(
                tStartMs: offsetMs + Int(segment.t0Centiseconds) * 10,
                tEndMs: offsetMs + Int(segment.t1Centiseconds) * 10,
                text: text
            )
        }
    }
}

/// Long-file windowing for whisper: decode 30 s windows and, like whisper's own seek loop, start the
/// next window where the last complete segment ended. A fixed 1 s overlap with "drop segments that
/// start before previous end − 500 ms" (the plan's first rule) lost whole sentences in the stt-bench
/// spike: whisper's first segment of a window often starts inside the overlap but runs for seconds.
enum WhisperWindowing {
    static let windowMs = 30_000
    static let windowSamples = windowMs * 16
    /// A segment ending this close to the window end may be cut mid-word; it is re-decoded next window.
    static let guardBandMs = 1_000

    struct Commit: Equatable {
        var kept: [TranscribedSegment]
        var nextStartMs: Int
    }

    /// Decides which of a window's segments are final and where the next window starts.
    /// - The last window keeps everything.
    /// - Otherwise keep segments ending ≤ window end − guard band; the next window starts at the last kept end.
    /// - Silence (no segments) advances by the window minus the guard band so a word on the edge is re-heard.
    /// - Segments that all run into the guard band (one long utterance) are kept whole to guarantee progress.
    static func commit(_ segments: [TranscribedSegment], windowStartMs: Int, windowEndMs: Int, isLast: Bool) -> Commit {
        if isLast { return Commit(kept: segments, nextStartMs: windowEndMs) }
        guard !segments.isEmpty else {
            return Commit(kept: [], nextStartMs: max(windowStartMs + 1, windowEndMs - guardBandMs))
        }
        let complete = segments.filter { $0.tEndMs <= windowEndMs - guardBandMs }
        guard let last = complete.last, last.tEndMs > windowStartMs else {
            return Commit(kept: segments, nextStartMs: windowEndMs)
        }
        return Commit(kept: complete, nextStartMs: last.tEndMs)
    }
}
