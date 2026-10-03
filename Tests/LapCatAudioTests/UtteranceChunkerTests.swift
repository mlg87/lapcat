import Foundation
import Testing

@testable import LapCatAudio

private let rate = 16_000

/// Deterministic low-level noise (≈ -55 dBFS) plus optional 220 Hz tone spans.
private func signal(seconds: Double, tones: [(start: Double, end: Double)]) -> [Float] {
    var generator = SplitMix(seed: 42)
    return (0..<Int(seconds * Double(rate))).map { index in
        let t = Double(index) / Double(rate)
        let noise = Float(generator.nextUnit() * 2 - 1) * 0.003
        let tone = tones.contains { t >= $0.start && t < $0.end } ? Float(0.3 * sin(2 * .pi * 220 * t)) : 0
        return noise + tone
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUnit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

/// Feeds in uneven slices so frame alignment across `append` calls is exercised.
private func run(_ chunker: UtteranceChunker, _ samples: [Float]) -> [UtteranceEvent] {
    var events: [UtteranceEvent] = []
    var offset = 0
    let sizes = [1_600, 333, 4_800, 17, 2_000]
    var index = 0
    while offset < samples.count {
        let end = min(samples.count, offset + sizes[index % sizes.count])
        events += chunker.append(Array(samples[offset..<end]))
        offset = end
        index += 1
    }
    return events
}

private func closedSpans(_ events: [UtteranceEvent]) -> [(start: Int, end: Int, count: Int)] {
    events.compactMap {
        if case .closed(let samples, let start, let end) = $0 { (start, end, samples.count) } else { nil }
    }
}

private func near(_ value: Int, _ expected: Int, tolerance: Int = 40) -> Bool {
    abs(value - expected) <= tolerance
}

@Test func burstsSeparatedBySilenceBecomeSeparateUtterances() {
    let bursts = [(0.5, 1.5), (3.0, 4.0), (5.5, 6.5)]
    let chunker = UtteranceChunker(hypothesisInterval: nil)
    let events = run(chunker, signal(seconds: 8, tones: bursts.map { (start: $0.0, end: $0.1) }))

    let spans = closedSpans(events)
    #expect(spans.count == 3)
    for (span, burst) in zip(spans, bursts) {
        #expect(near(span.start, Int(burst.0 * 1000)), "start \(span.start) vs \(burst.0)")
        #expect(near(span.end, Int(burst.1 * 1000)), "end \(span.end) vs \(burst.1)")
        #expect(span.count == (span.end - span.start) * rate / 1000)
    }
    let opened = events.compactMap { if case .opened(let t) = $0 { t } else { nil } }
    #expect(opened == spans.map(\.start))
    #expect(chunker.flush().isEmpty)
}

@Test func shortBlipDoesNotOpenAnUtterance() {
    let chunker = UtteranceChunker(hypothesisInterval: nil)
    let events = run(chunker, signal(seconds: 3, tones: [(start: 1.0, end: 1.2)]))
    #expect(events.isEmpty)
}

@Test func continuousToneIsCutAtFifteenSecondsAndContinues() {
    let chunker = UtteranceChunker(hypothesisInterval: nil)
    let events = run(chunker, signal(seconds: 22, tones: [(start: 0, end: 20)]))

    let spans = closedSpans(events)
    #expect(spans.count == 2)
    #expect(near(spans[0].start, 0))
    #expect(near(spans[0].end, 15_000))
    #expect(spans[0].end - spans[0].start <= 15_000)
    #expect(spans[1].start == spans[0].end)
    #expect(near(spans[1].end, 20_000))
}

@Test func hypothesesAreEmittedWhileOpen() {
    let chunker = UtteranceChunker(hypothesisInterval: 2.0)
    let events = run(chunker, signal(seconds: 9, tones: [(start: 1.0, end: 8.0)]))

    let hypotheses = events.compactMap {
        if case .hypothesis(let samples, let start) = $0 { (samples.count, start) } else { nil }
    }
    // 7 s of speech → hypotheses at 2, 4 and 6 s of utterance audio.
    #expect(hypotheses.count == 3)
    #expect(hypotheses.allSatisfy { near($0.1, 1_000) })
    #expect(hypotheses.map(\.0) == hypotheses.map(\.0).sorted())
    if let first = hypotheses.first { #expect(abs(first.0 - 2 * rate) <= 320) }
    // Every hypothesis precedes the close.
    let lastHypothesis = events.lastIndex { if case .hypothesis = $0 { true } else { false } }
    let close = events.firstIndex { if case .closed = $0 { true } else { false } }
    #expect(lastHypothesis! < close!)
}

@Test func flushClosesAnOpenUtterance() {
    let chunker = UtteranceChunker(hypothesisInterval: nil, startMs: 10_000)
    let events = run(chunker, signal(seconds: 3, tones: [(start: 1.0, end: 3.0)]))
    #expect(closedSpans(events).isEmpty)
    #expect(events.contains { if case .opened(let t) = $0 { near(t, 11_000) } else { false } })

    let flushed = closedSpans(chunker.flush())
    #expect(flushed.count == 1)
    #expect(near(flushed[0].start, 11_000))
    #expect(near(flushed[0].end, 13_000))
}
