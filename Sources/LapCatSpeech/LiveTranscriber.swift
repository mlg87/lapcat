import Foundation
import LapCatAudio
import LapCatCore
import os

/// Turns one channel's live audio into `pass='live'` segments while a meeting records.
///
/// Audio goes through `UtteranceChunker`; each closed utterance is transcribed and appended,
/// and (when hypotheses are on) the channel's single volatile row is replaced with a fresh guess.
/// Work runs one item at a time per channel. When more than `maxBacklog` closed utterances are
/// waiting, hypotheses are skipped and `laggingBehind` is reported — audio is never dropped,
/// since it is already on disk and the final pass re-transcribes it.
public actor LiveTranscriber {
    public enum Event: Sendable, Equatable {
        /// Queued speech the engine has not reached yet.
        case laggingBehind(Channel, seconds: Double)
        case caughtUp(Channel)
        /// The engine could not be prepared; live transcription for this channel is off.
        case unavailable(Channel, reason: String)
    }

    private enum Work {
        case utterance(samples: [Float], tStartMs: Int, tEndMs: Int)
        case hypothesis(samples: [Float], tStartMs: Int)
    }

    public nonisolated let events: AsyncStream<Event>
    private nonisolated let continuation: AsyncStream<Event>.Continuation
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "LiveTranscriber")

    private let meetingID: String
    private let channel: Channel
    private let store: Store
    private let makeEngine: @Sendable () async throws -> any TranscriptionEngine
    private let hypothesisInterval: TimeInterval?
    private let maxBacklog: Int

    private var chunker: UtteranceChunker?
    private var queue: [Work] = []
    private var worker: Task<Void, Never>?
    private var engine: (any TranscriptionEngine)?
    private var engineFailed = false
    private var lagging = false
    /// End of the last stored live segment: keeps segments within the channel non-overlapping.
    private var lastEndMs = 0

    /// `makeEngine` is called once, on the first utterance (it may download and load a model).
    public init(
        meetingID: String, channel: Channel, store: Store,
        hypothesisInterval: TimeInterval?, maxBacklog: Int = 3,
        makeEngine: @escaping @Sendable () async throws -> any TranscriptionEngine
    ) {
        self.meetingID = meetingID
        self.channel = channel
        self.store = store
        self.hypothesisInterval = hypothesisInterval
        self.maxBacklog = maxBacklog
        self.makeEngine = makeEngine
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(16))
    }

    /// Feeds contiguous 16 kHz mono samples that start at `tStartMs` on the session clock.
    public func append(_ samples: [Float], tStartMs: Int) {
        if chunker == nil {
            chunker = UtteranceChunker(hypothesisInterval: hypothesisInterval, startMs: tStartMs)
        }
        guard let events = chunker?.append(samples) else { return }
        handle(events)
    }

    /// Ends the channel and waits for the worker to stop.
    ///
    /// With `discardBacklog` (the meeting is ending and the final pass will re-transcribe the
    /// recording) queued utterances are dropped and only the one in flight completes; without it,
    /// the open utterance is closed and every queued utterance is transcribed and stored.
    public func finish(discardBacklog: Bool = false) async {
        if discardBacklog {
            queue.removeAll()
        } else if let events = chunker?.flush() {
            handle(events)
        }
        // Hypotheses are moot once the channel has ended.
        queue.removeAll { if case .hypothesis = $0 { true } else { false } }
        while let worker {
            await worker.value
            if self.worker == worker { self.worker = nil }
        }
        _ = try? await store.replaceVolatileSegment(meetingID: meetingID, channel: channel, with: nil)
        continuation.finish()
    }

    private func handle(_ events: [UtteranceEvent]) {
        for event in events {
            switch event {
            case .opened:
                break
            case .hypothesis(let samples, let tStartMs):
                // A newer guess supersedes an older one still waiting; skip entirely when behind.
                queue.removeAll { if case .hypothesis = $0 { true } else { false } }
                if backlog < 1 { queue.append(.hypothesis(samples: samples, tStartMs: tStartMs)) }
            case .closed(let samples, let tStartMs, let tEndMs):
                queue.removeAll { if case .hypothesis = $0 { true } else { false } }
                queue.append(.utterance(samples: samples, tStartMs: tStartMs, tEndMs: tEndMs))
            }
        }
        reportLag()
        startWorkerIfNeeded()
    }

    private var backlog: Int {
        queue.reduce(0) { count, work in if case .utterance = work { count + 1 } else { count } }
    }

    private func reportLag() {
        if backlog > maxBacklog {
            let seconds = queue.reduce(0.0) { total, work in
                if case .utterance(_, let start, let end) = work { total + Double(end - start) / 1000 } else { total }
            }
            lagging = true
            continuation.yield(.laggingBehind(channel, seconds: seconds))
        } else if lagging, backlog == 0 {
            lagging = false
            continuation.yield(.caughtUp(channel))
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let work = queue.removeFirst()
            await process(work)
            reportLag()
        }
        worker = nil
    }

    private func preparedEngine() async -> (any TranscriptionEngine)? {
        if let engine { return engine }
        if engineFailed { return nil }
        do {
            let engine = try await makeEngine()
            try await engine.load()
            self.engine = engine
            return engine
        } catch {
            engineFailed = true
            Self.logger.error("live engine unavailable for \(self.channel.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            continuation.yield(.unavailable(channel, reason: String(describing: error)))
            return nil
        }
    }

    private func process(_ work: Work) async {
        guard let engine = await preparedEngine() else { return }
        do {
            switch work {
            case .utterance(let samples, let tStartMs, let tEndMs):
                let recognised = try await engine.transcribe(samples, offsetMs: tStartMs)
                let segments = Self.liveSegments(
                    recognised, meetingID: meetingID, channel: channel,
                    utterance: tStartMs...tEndMs, notBefore: lastEndMs)
                if let last = segments.last { lastEndMs = last.tEndMs }
                try await store.appendSegments(segments)
                try await store.replaceVolatileSegment(meetingID: meetingID, channel: channel, with: nil)
            case .hypothesis(let samples, let tStartMs):
                let recognised = try await engine.transcribe(samples, offsetMs: tStartMs)
                let text = recognised.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return }
                let guess = Segment(
                    meetingID: meetingID, channel: channel, tStartMs: tStartMs,
                    tEndMs: tStartMs + samples.count / 16, text: text, pass: .live, isVolatile: true)
                try await store.replaceVolatileSegment(meetingID: meetingID, channel: channel, with: guess)
            }
        } catch {
            Self.logger.error("live transcription failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Engine output → stored rows: blank text dropped, times clamped into the utterance and
    /// after `notBefore`, so a channel's live segments never overlap and stay in order.
    static func liveSegments(
        _ recognised: [TranscribedSegment], meetingID: String, channel: Channel,
        utterance: ClosedRange<Int>, notBefore: Int
    ) -> [Segment] {
        var cursor = max(notBefore, utterance.lowerBound)
        var result: [Segment] = []
        for item in recognised {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = min(max(item.tStartMs, cursor), utterance.upperBound)
            let end = min(max(item.tEndMs, start), utterance.upperBound)
            guard end > start else { continue }
            result.append(Segment(
                meetingID: meetingID, channel: channel, tStartMs: start, tEndMs: end, text: text,
                confidence: item.confidence.map(Double.init), pass: .live))
            cursor = end
        }
        return result
    }
}
