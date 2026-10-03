import Testing
@testable import LapCatSpeech

@Suite struct SentenceGrouperTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(word: text, startTime: start, endTime: end)
    }

    @Test func splitsAtSentencePunctuation() {
        let words = [
            word("We", 0.10, 0.25), word("agreed.", 0.30, 0.70),
            word("Any", 0.80, 0.95), word("questions?", 1.00, 1.50),
            word("Great!", 1.60, 2.00),
        ]
        let segments = SentenceGrouper.group(words, offsetMs: 10_000, confidence: 0.9)
        #expect(
            segments == [
                TranscribedSegment(tStartMs: 10_100, tEndMs: 10_700, text: "We agreed.", confidence: 0.9),
                TranscribedSegment(tStartMs: 10_800, tEndMs: 11_500, text: "Any questions?", confidence: 0.9),
                TranscribedSegment(tStartMs: 11_600, tEndMs: 12_000, text: "Great!", confidence: 0.9),
            ])
    }

    @Test func splitsOnGapsLongerThan800msOnly() {
        let words = [
            word("so", 0.0, 0.2), word("then", 1.0, 1.2),  // 800 ms gap: same sentence
            word("pricing", 2.001, 2.4),  // 801 ms gap: new sentence
            word("goes", 2.5, 2.7), word("up", 2.8, 3.0),  // no terminal punctuation: closed at end
        ]
        let segments = SentenceGrouper.group(words, offsetMs: 0, confidence: nil)
        #expect(segments.map(\.text) == ["so then", "pricing goes up"])
        #expect(segments.map(\.tStartMs) == [0, 2_001])
        #expect(segments.map(\.tEndMs) == [1_200, 3_000])
    }

    @Test func noWordsYieldsNoSegments() {
        #expect(SentenceGrouper.group([], offsetMs: 0, confidence: nil).isEmpty)
    }

    @Test func fallbackSpansWholeChunkWhenTimingsAreMissing() {
        let segments = SentenceGrouper.fallback(
            text: " Hello world. ", offsetMs: 5_000, sampleCount: 48_000, confidence: 0.5)
        #expect(segments == [TranscribedSegment(tStartMs: 5_000, tEndMs: 8_000, text: "Hello world.", confidence: 0.5)])
        #expect(SentenceGrouper.fallback(text: "  ", offsetMs: 0, sampleCount: 16_000, confidence: nil).isEmpty)
    }
}
