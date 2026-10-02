import Foundation
import LapCatCore
import Testing
@testable import LapCatSpeech

@Suite struct NameMapperTests {
    private func assignments(_ segments: [Segment], turns: [DiarizedTurn] = [], events: [SpeakerEvent] = []) -> [Int64: SegmentAssignment] {
        Dictionary(uniqueKeysWithValues: NameMapper.assign(segments: segments, turns: turns, events: events, meName: "Mason").map { ($0.segmentID, $0) })
    }

    @Test func micSegmentsAlwaysGoToMeEvenWithOtherEvidence() {
        let result = assignments(
            [segment(1, .mic, 0, 4_000)],
            turns: [DiarizedTurn(startMs: 0, endMs: 4_000, cluster: "Speaker 1")],
            events: [event("Priya", 0, 4_000)]
        )
        #expect(result[1] == SegmentAssignment(segmentID: 1, participantName: "Mason", cluster: nil, basis: .me))
    }

    @Test func largestSummedEventOverlapWins() {
        // Tom has two short events (1.5 s + 1.5 s = 3 s, 46 %) vs Priya's single 2.5 s event (38 %).
        let result = assignments(
            [segment(1, .system, 0, 6_500)],
            events: [event("Tom", 0, 1_500), event("Priya", 2_000, 4_500), event("Tom", 5_000, 6_500)]
        )
        #expect(result[1]?.participantName == "Tom")
        #expect(result[1]?.basis == .speakerEvents)
    }

    @Test func fortyPercentCoverageIsTheThreshold() {
        let turns = [DiarizedTurn(startMs: 0, endMs: 20_000, cluster: "Speaker 1")]
        let exactly = assignments([segment(1, .system, 0, 10_000)], turns: turns, events: [event("Tom", 0, 4_000)])
        #expect(exactly[1]?.participantName == "Tom")
        #expect(exactly[1]?.basis == .speakerEvents)

        let below = assignments([segment(1, .system, 0, 10_000)], turns: turns, events: [event("Tom", 0, 3_999)])
        #expect(below[1]?.participantName == "Speaker 1")
        #expect(below[1]?.basis == .cluster)
    }

    @Test func openEventCountsUntilTheSegmentEnds() {
        let result = assignments([segment(1, .system, 5_000, 9_000)], events: [event("Tom", 6_000, nil)])
        #expect(result[1]?.participantName == "Tom")
    }

    @Test func clusterVoteNamesSegmentsWithoutDirectEvidence() {
        let turns = [
            DiarizedTurn(startMs: 0, endMs: 30_000, cluster: "Speaker 1"),
            DiarizedTurn(startMs: 30_000, endMs: 40_000, cluster: "Speaker 2"),
        ]
        let segments = [
            segment(1, .system, 0, 5_000),        // Tom directly
            segment(2, .system, 5_000, 10_000),   // Tom directly
            segment(3, .system, 10_000, 15_000),  // Priya directly (same cluster, minority)
            segment(4, .system, 20_000, 25_000),  // no events → cluster vote → Tom
            segment(5, .system, 31_000, 35_000),  // Speaker 2, nobody named → Speaker 2
        ]
        let events = [event("Tom", 0, 10_000), event("Priya", 10_000, 15_000)]
        let result = assignments(segments, turns: turns, events: events)
        #expect(result[3]?.participantName == "Priya")
        #expect(result[4] == SegmentAssignment(segmentID: 4, participantName: "Tom", cluster: "Speaker 1", basis: .clusterVote))
        #expect(result[5] == SegmentAssignment(segmentID: 5, participantName: "Speaker 2", cluster: "Speaker 2", basis: .cluster))
    }

    @Test func clusterIsTheTurnWithMaximalOverlap() {
        let turns = [
            DiarizedTurn(startMs: 0, endMs: 3_000, cluster: "Speaker 1"),
            DiarizedTurn(startMs: 3_000, endMs: 10_000, cluster: "Speaker 2"),
        ]
        let result = assignments([segment(1, .system, 2_000, 6_000)], turns: turns)
        #expect(result[1]?.cluster == "Speaker 2")
    }

    @Test func systemSegmentWithoutTurnOrEventsStaysUnassigned() {
        let result = assignments([segment(1, .system, 50_000, 51_000)], turns: [DiarizedTurn(startMs: 0, endMs: 1_000, cluster: "Speaker 1")])
        #expect(result[1] == SegmentAssignment(segmentID: 1, participantName: nil, cluster: nil, basis: .unassigned))
    }

    @Test func liveAndVolatileSegmentsAreIgnored() {
        var volatile = segment(2, .system, 0, 1_000)
        volatile.isVolatile = true
        let result = assignments([segment(1, .system, 0, 1_000, pass: .live), volatile])
        #expect(result.isEmpty)
    }
}
