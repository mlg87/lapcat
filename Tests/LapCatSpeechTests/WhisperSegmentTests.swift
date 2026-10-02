import Testing
@testable import LapCatSpeech

@Suite struct WhisperSegmentFilterTests {
    @Test func dropsEmptyAndNonSpeechSegmentsAndKeepsSpeech() {
        let raw = [
            WhisperRawSegment(t0Centiseconds: 0, t1Centiseconds: 120, text: " [BLANK_AUDIO]"),
            WhisperRawSegment(t0Centiseconds: 120, t1Centiseconds: 250, text: " Hello there."),
            WhisperRawSegment(t0Centiseconds: 250, t1Centiseconds: 300, text: "   "),
            WhisperRawSegment(t0Centiseconds: 300, t1Centiseconds: 400, text: " (music)"),
            WhisperRawSegment(t0Centiseconds: 400, t1Centiseconds: 520, text: " [Music] plays (softly)"),
        ]
        let segments = WhisperSegmentFilter.segments(from: raw, offsetMs: 0)
        #expect(segments.map(\.text) == ["Hello there.", "[Music] plays (softly)"])
    }

    @Test func convertsCentisecondsToMillisecondsAndAppliesOffset() {
        let raw = [WhisperRawSegment(t0Centiseconds: 123, t1Centiseconds: 456, text: " Pricing goes up.")]
        let segments = WhisperSegmentFilter.segments(from: raw, offsetMs: 60_000)
        #expect(segments == [TranscribedSegment(tStartMs: 61_230, tEndMs: 64_560, text: "Pricing goes up.")])
    }
}

@Suite struct WhisperWindowingTests {
    private func segment(_ start: Int, _ end: Int) -> TranscribedSegment {
        TranscribedSegment(tStartMs: start, tEndMs: end, text: "s\(start)")
    }

    @Test func lastWindowKeepsEverything() {
        let segments = [segment(60_000, 70_000), segment(70_000, 74_900)]
        let commit = WhisperWindowing.commit(segments, windowStartMs: 60_000, windowEndMs: 75_000, isLast: true)
        #expect(commit.kept == segments)
    }

    @Test func segmentEndingInsideGuardBandIsDeferredToNextWindow() {
        // Window 30 s…60 s: the segment ending at 59.5 s may be cut mid-word, so it is re-decoded.
        let segments = [segment(30_000, 41_000), segment(41_000, 59_000), segment(59_000, 59_500)]
        let commit = WhisperWindowing.commit(segments, windowStartMs: 30_000, windowEndMs: 60_000, isLast: false)
        #expect(commit.kept.map(\.tStartMs) == [30_000, 41_000])
        #expect(commit.nextStartMs == 59_000)
    }

    @Test func silentWindowAdvancesButReHearsTheGuardBand() {
        let commit = WhisperWindowing.commit([], windowStartMs: 0, windowEndMs: 30_000, isLast: false)
        #expect(commit.kept.isEmpty)
        #expect(commit.nextStartMs == 29_000)
    }

    @Test func singleSegmentRunningIntoGuardBandIsKeptToGuaranteeProgress() {
        let segments = [segment(0, 30_000)]
        let commit = WhisperWindowing.commit(segments, windowStartMs: 0, windowEndMs: 30_000, isLast: false)
        #expect(commit.kept == segments)
        #expect(commit.nextStartMs == 30_000)
    }
}
