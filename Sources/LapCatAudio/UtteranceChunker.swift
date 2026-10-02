import Foundation

public enum UtteranceEvent: Sendable {
    /// Speech started at `tStartMs` (emitted once 300 ms of speech have been seen).
    case opened(tStartMs: Int)
    /// Audio of the still-open utterance so far, every `hypothesisInterval` of utterance audio.
    case hypothesis(samples: [Float], tStartMs: Int)
    /// A finished utterance: `samples` span exactly `tStartMs..<tEndMs`.
    case closed(samples: [Float], tStartMs: Int, tEndMs: Int)
}

/// Splits a contiguous 16 kHz mono stream into utterances with `EnergyVAD`: open after 300 ms
/// of speech, close after 700 ms of silence, force-cut at 15 s (Parakeet's maximum window).
///
/// Not thread-safe; feed it from one queue or actor. Its clock starts at `startMs` and advances
/// by the samples appended.
public final class UtteranceChunker {
    public static let sampleRate = EnergyVAD.sampleRate
    static let openSpeechSamples = 300 * sampleRate / 1000
    static let closeSilenceSamples = 700 * sampleRate / 1000
    static let maxUtteranceSamples = 15 * sampleRate
    /// A candidate onset is abandoned after this much non-speech before it opens.
    static let candidateGapSamples = 100 * sampleRate / 1000

    private let frame = EnergyVAD.frameSamples
    private let hypothesisSamples: Int?
    private let startMs: Int
    private var vad = EnergyVAD()
    private var remainder: [Float] = []
    /// Absolute sample index of the next frame.
    private var position = 0

    private enum State {
        case idle
        case candidate(start: Int, speech: Int, gap: Int)
        case open(start: Int, lastSpeechEnd: Int, silence: Int, hypothesizedCount: Int)
    }

    private var state = State.idle
    /// Samples from the candidate/utterance start up to `position`.
    private var buffer: [Float] = []

    public init(hypothesisInterval: TimeInterval?, startMs: Int = 0) {
        hypothesisSamples = hypothesisInterval.map { max(1, Int($0 * Double(Self.sampleRate))) }
        self.startMs = startMs
    }

    public func append(_ samples: [Float]) -> [UtteranceEvent] {
        var events: [UtteranceEvent] = []
        remainder.append(contentsOf: samples)
        var offset = 0
        remainder.withUnsafeBufferPointer { all in
            while all.count - offset >= frame {
                let slice = UnsafeBufferPointer(rebasing: all[offset..<offset + frame])
                process(slice, into: &events)
                offset += frame
            }
        }
        remainder.removeFirst(offset)
        return events
    }

    /// Closes an open utterance at its last speech frame. Pending partial frames are dropped.
    public func flush() -> [UtteranceEvent] {
        var events: [UtteranceEvent] = []
        if case .open(let start, let lastSpeechEnd, _, _) = state {
            close(start: start, end: lastSpeechEnd, into: &events)
        }
        state = .idle
        buffer = []
        remainder = []
        return events
    }

    private func ms(_ sample: Int) -> Int { startMs + sample * 1000 / Self.sampleRate }

    private func process(_ samples: UnsafeBufferPointer<Float>, into events: inout [UtteranceEvent]) {
        let frameStart = position
        let frameEnd = position + frame
        position = frameEnd
        let speech = vad.isSpeech(samples)

        switch state {
        case .idle:
            guard speech else { return }
            buffer = Array(samples)
            state = .candidate(start: frameStart, speech: frame, gap: 0)
            openIfReady(into: &events)

        case .candidate(let start, let speechSamples, let gap):
            buffer.append(contentsOf: samples)
            if speech {
                state = .candidate(start: start, speech: speechSamples + frame, gap: 0)
                openIfReady(into: &events)
            } else if gap + frame >= Self.candidateGapSamples {
                state = .idle
                buffer = []
            } else {
                state = .candidate(start: start, speech: speechSamples, gap: gap + frame)
            }

        case .open(let start, var lastSpeechEnd, var silence, var hypothesized):
            buffer.append(contentsOf: samples)
            if speech {
                lastSpeechEnd = frameEnd
                silence = 0
            } else {
                silence += frame
            }
            if silence >= Self.closeSilenceSamples {
                close(start: start, end: lastSpeechEnd, into: &events)
                state = .idle
                return
            }
            if frameEnd - start >= Self.maxUtteranceSamples {
                if speech {
                    close(start: start, end: frameEnd, into: &events)
                    buffer = []
                    state = .open(start: frameEnd, lastSpeechEnd: frameEnd, silence: 0, hypothesizedCount: 0)
                    events.append(.opened(tStartMs: ms(frameEnd)))
                } else {
                    close(start: start, end: lastSpeechEnd, into: &events)
                    state = .idle
                }
                return
            }
            if let hypothesisSamples, buffer.count - hypothesized >= hypothesisSamples {
                hypothesized = buffer.count
                events.append(.hypothesis(samples: buffer, tStartMs: ms(start)))
            }
            state = .open(start: start, lastSpeechEnd: lastSpeechEnd, silence: silence, hypothesizedCount: hypothesized)
        }
    }

    private func openIfReady(into events: inout [UtteranceEvent]) {
        guard case .candidate(let start, let speech, _) = state, speech >= Self.openSpeechSamples else { return }
        state = .open(start: start, lastSpeechEnd: position, silence: 0, hypothesizedCount: 0)
        events.append(.opened(tStartMs: ms(start)))
    }

    private func close(start: Int, end: Int, into events: inout [UtteranceEvent]) {
        let count = max(0, min(end - start, buffer.count))
        events.append(.closed(samples: Array(buffer.prefix(count)), tStartMs: ms(start), tEndMs: ms(start + count)))
        buffer = []
    }
}
