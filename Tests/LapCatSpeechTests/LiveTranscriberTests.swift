import Foundation
import Testing
import LapCatCore
@testable import LapCatSpeech

/// Engine double: returns one segment per call covering the given samples, or throws on load.
private actor FakeEngine: TranscriptionEngine {
    nonisolated let id = "fake"
    let failLoad: Bool
    private(set) var calls: [(count: Int, offsetMs: Int)] = []

    init(failLoad: Bool = false) { self.failLoad = failLoad }

    func load() async throws { if failLoad { throw SpeechError.modelLoadFailed("boom") } }
    func transcribe(_ samples16k: [Float], offsetMs: Int) async throws -> [TranscribedSegment] {
        calls.append((samples16k.count, offsetMs))
        return [TranscribedSegment(tStartMs: offsetMs, tEndMs: offsetMs + samples16k.count / 16, text: "words \(calls.count)")]
    }
    func transcribeFile(_ url: URL, progress: @Sendable (Double) -> Void) async throws -> [TranscribedSegment] { [] }
    func unload() async {}
}

struct LiveTranscriberTests {
    private func makeStore() throws -> (Store, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try Store(databaseURL: dir.appendingPathComponent("lapcat.sqlite")), dir.path)
    }

    /// `silence` seconds of low noise then `tone` seconds of a loud 220 Hz tone, repeated.
    private func bursts(_ count: Int, tone: Double = 1.0, silence: Double = 1.5) -> [Float] {
        var out: [Float] = []
        var seed: UInt32 = 1
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return (Float(seed % 1000) / 1000 - 0.5) * 0.002 }
        for _ in 0..<count {
            out += (0..<Int(silence * 16_000)).map { _ in noise() }
            out += (0..<Int(tone * 16_000)).map { i in 0.3 * sin(2 * .pi * 220 * Float(i) / 16_000) }
        }
        out += (0..<Int(silence * 16_000)).map { _ in noise() }
        return out
    }

    @Test func closedUtterancesBecomeOrderedNonOverlappingLiveSegments() async throws {
        let (store, _) = try makeStore()
        let meeting = try await store.createMeeting(title: "t", startedBy: .manual)
        let engine = FakeEngine()
        let transcriber = LiveTranscriber(
            meetingID: meeting.id, channel: .system, store: store, hypothesisInterval: nil, makeEngine: { engine })
        let audio = bursts(3)
        // Deliver in 100 ms chunks on the session clock, as CaptureSession does.
        var offset = 0
        while offset < audio.count {
            let end = min(offset + 1600, audio.count)
            await transcriber.append(Array(audio[offset..<end]), tStartMs: offset / 16)
            offset = end
        }
        await transcriber.finish()

        let segments = try await store.segments(meetingID: meeting.id, pass: .live)
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { !$0.isVolatile && $0.channel == .system })
        for (a, b) in zip(segments, segments.dropFirst()) { #expect(a.tEndMs <= b.tStartMs) }
        // First burst starts after 1.5 s of silence.
        #expect(abs(segments[0].tStartMs - 1500) <= 60)
    }

    @Test func engineThatFailsToLoadReportsUnavailableAndStoresNothing() async throws {
        let (store, _) = try makeStore()
        let meeting = try await store.createMeeting(title: "t", startedBy: .manual)
        let engine = FakeEngine(failLoad: true)
        let transcriber = LiveTranscriber(
            meetingID: meeting.id, channel: .mic, store: store, hypothesisInterval: nil, makeEngine: { engine })
        await transcriber.append(bursts(1), tStartMs: 0)
        await transcriber.finish()
        var received: [LiveTranscriber.Event] = []
        for await event in transcriber.events { received.append(event) }
        #expect(received.contains { if case .unavailable(.mic, _) = $0 { true } else { false } })
        #expect(try await store.segments(meetingID: meeting.id).isEmpty)
    }

    @Test func hypothesesLeaveNoVolatileRowAfterFinish() async throws {
        let (store, _) = try makeStore()
        let meeting = try await store.createMeeting(title: "t", startedBy: .manual)
        let engine = FakeEngine()
        let transcriber = LiveTranscriber(
            meetingID: meeting.id, channel: .mic, store: store, hypothesisInterval: 0.5, makeEngine: { engine })
        await transcriber.append(bursts(1, tone: 4), tStartMs: 0)
        await transcriber.finish()
        let segments = try await store.segments(meetingID: meeting.id)
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { !$0.isVolatile })
    }

    @Test func engineTimesAreClampedIntoTheUtteranceAndAfterThePreviousSegment() {
        let recognised = [
            TranscribedSegment(tStartMs: 900, tEndMs: 1_500, text: "a"),   // starts before the utterance/previous end
            TranscribedSegment(tStartMs: 1_400, tEndMs: 2_000, text: "b"), // overlaps "a"
            TranscribedSegment(tStartMs: 2_500, tEndMs: 9_000, text: "c"), // runs past the utterance
            TranscribedSegment(tStartMs: 2_600, tEndMs: 2_700, text: "  "), // blank
        ]
        let rows = LiveTranscriber.liveSegments(
            recognised, meetingID: "m", channel: .mic, utterance: 1_000...3_000, notBefore: 1_200)
        #expect(rows.map(\.text) == ["a", "b", "c"])
        #expect(rows.map(\.tStartMs) == [1_200, 1_500, 2_500])
        #expect(rows.map(\.tEndMs) == [1_500, 2_000, 3_000])
    }
}
