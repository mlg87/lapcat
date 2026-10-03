import Foundation
import Testing

@testable import LapCatCore

struct LiveMergeTests {
    private func seg(
        _ id: Int64, _ channel: Channel, _ start: Int, _ end: Int, _ text: String, pass: SegmentPass,
        edited: Bool = false, participant: Int64? = nil
    ) -> Segment {
        Segment(
            id: id, meetingID: "m", channel: channel, tStartMs: start, tEndMs: end, text: text,
            participantID: participant, pass: pass, editedAt: edited ? Date() : nil)
    }

    @Test func editGoesToTheSameChannelFinalSegmentWithTheLargestOverlap() {
        let live = [seg(1, .system, 1_000, 4_000, "fixed text", pass: .live, edited: true)]
        let final = [
            seg(10, .system, 0, 1_500, "a", pass: .final),  // 500 ms overlap
            seg(11, .system, 1_500, 3_800, "b", pass: .final),  // 2300 ms overlap
            seg(12, .mic, 1_000, 4_000, "c", pass: .final),  // other channel: ignored
        ]
        #expect(
            LiveMerge.plan(live: live, final: final) == [
                .init(finalID: 11, text: "fixed text", textOriginal: "b", participantID: nil)
            ])
    }

    @Test func untouchedLiveSegmentsAndNonOverlappingOnesProduceNoUpdates() {
        let live = [
            seg(1, .mic, 0, 1_000, "plain", pass: .live),
            seg(2, .mic, 5_000, 6_000, "edited", pass: .live, edited: true),
        ]
        let final = [seg(10, .mic, 0, 4_000, "x", pass: .final), seg(11, .mic, 6_000, 7_000, "touching", pass: .final)]
        // Live 2 only touches final 11 at its boundary (0 ms overlap) — no target.
        #expect(LiveMerge.plan(live: live, final: final).isEmpty)
    }

    @Test func speakerAssignmentCarriesOverWithoutTouchingText() {
        let live = [seg(1, .system, 0, 2_000, "hi", pass: .live, participant: 7)]
        let final = [seg(10, .system, 100, 2_100, "hi there", pass: .final)]
        #expect(
            LiveMerge.plan(live: live, final: final) == [
                .init(finalID: 10, text: nil, textOriginal: nil, participantID: 7)
            ])
    }

    @Test func whenTwoLiveSegmentsMapToOneFinalTheStrongerEditWinsAndAssignmentsCombine() {
        let live = [
            seg(1, .system, 0, 500, "weak edit", pass: .live, edited: true, participant: 3),
            seg(2, .system, 500, 3_000, "strong edit", pass: .live, edited: true),
        ]
        let final = [seg(10, .system, 0, 3_000, "orig", pass: .final)]
        #expect(
            LiveMerge.plan(live: live, final: final) == [
                .init(finalID: 10, text: "strong edit", textOriginal: "orig", participantID: 3)
            ])
    }

    @Test func mergeIntoFinalAppliesEditsThenDropsLiveRows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(databaseURL: dir.appendingPathComponent("lapcat.sqlite"))
        let meeting = try await store.createMeeting(title: "t", startedBy: .manual)
        let live = try await store.appendSegments([
            Segment(meetingID: meeting.id, channel: .mic, tStartMs: 0, tEndMs: 2_000, text: "teh plan", pass: .live)
        ])
        try await store.updateSegmentText(id: live[0].id!, text: "the plan")
        try await store.replaceFinalSegments(
            meetingID: meeting.id, channel: .mic,
            with: [
                Segment(
                    meetingID: meeting.id, channel: .mic, tStartMs: 100, tEndMs: 1_900, text: "the plain", pass: .final)
            ])
        try await store.mergeLiveIntoFinal(meetingID: meeting.id)

        let rows = try await store.segments(meetingID: meeting.id)
        #expect(rows.count == 1)
        #expect(rows[0].pass == .final)
        #expect(rows[0].text == "the plan")
        #expect(rows[0].textOriginal == "the plain")
        #expect(rows[0].editedAt != nil)
    }

    @Test func mergeWithoutFinalSegmentsKeepsTheLiveTranscript() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(databaseURL: dir.appendingPathComponent("lapcat.sqlite"))
        let meeting = try await store.createMeeting(title: "t", startedBy: .manual)
        try await store.appendSegments([
            Segment(meetingID: meeting.id, channel: .mic, tStartMs: 0, tEndMs: 2_000, text: "only live", pass: .live)
        ])
        try await store.mergeLiveIntoFinal(meetingID: meeting.id)
        #expect(try await store.segments(meetingID: meeting.id).map(\.text) == ["only live"])
    }
}

struct MeetingTitleTests {
    @Test func defaultTitleRoundTripsThroughIsDefault() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let title = MeetingTitle.default(for: date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(title == "Note 2026-09-21 14:13")
        #expect(MeetingTitle.isDefault(title))
        #expect(!MeetingTitle.isDefault("Note 2026-09-21 14:13 — pricing"))
        #expect(!MeetingTitle.isDefault("Weekly sync"))
    }
}
