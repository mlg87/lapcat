import Foundation
import Testing

@testable import LapCatCore

struct SpeakerStoreTests {
    private func setup() async throws -> (Store, Meeting, [Segment], Participant) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(databaseURL: dir.appendingPathComponent("lapcat.sqlite"))
        let meeting = try await store.createMeeting(title: "t", startedBy: .manual)
        let me = try await store.upsertParticipant(meetingID: meeting.id, name: "Mason", source: .manual, isMe: true)
        let segments =
            try await store.replaceFinalSegments(
                meetingID: meeting.id, channel: .system,
                with: [
                    Segment(
                        meetingID: meeting.id, channel: .system, tStartMs: 0, tEndMs: 1_000, text: "a", pass: .final),
                    Segment(
                        meetingID: meeting.id, channel: .system, tStartMs: 1_000, tEndMs: 2_000, text: "b", pass: .final
                    ),
                    Segment(
                        meetingID: meeting.id, channel: .system, tStartMs: 2_000, tEndMs: 3_000, text: "c", pass: .final
                    ),
                ])
            + store.replaceFinalSegments(
                meetingID: meeting.id, channel: .mic,
                with: [
                    Segment(meetingID: meeting.id, channel: .mic, tStartMs: 0, tEndMs: 900, text: "hi", pass: .final)
                ])
        return (store, meeting, segments, me)
    }

    @Test func assignmentsCreateParticipantsByKindAndAreIdempotent() async throws {
        let (store, meeting, s, me) = try await setup()
        let rows = [
            SpeakerAssignmentRow(segmentID: s[0].id!, kind: .named("Priya Shah"), cluster: "Speaker 1"),
            SpeakerAssignmentRow(segmentID: s[1].id!, kind: .cluster("Speaker 2"), cluster: "Speaker 2"),
            SpeakerAssignmentRow(segmentID: s[2].id!, kind: .unassigned, cluster: nil),
            SpeakerAssignmentRow(segmentID: s[3].id!, kind: .me, cluster: nil),
        ]
        try await store.applySpeakerAssignments(meetingID: meeting.id, rows: rows, namedSource: .zoomAX)
        try await store.applySpeakerAssignments(meetingID: meeting.id, rows: rows, namedSource: .zoomAX)

        let participants = try await store.participants(meetingID: meeting.id)
        #expect(participants.count == 3)
        let priya = try #require(participants.first { $0.displayName == "Priya Shah" })
        let cluster = try #require(participants.first { $0.displayName == "Speaker 2" })
        #expect(priya.source == .zoomAX)
        #expect(cluster.source == .cluster && cluster.clusterLabel == "Speaker 2")

        let byID = Dictionary(
            uniqueKeysWithValues: try await store.segments(meetingID: meeting.id).map { ($0.id!, $0) })
        #expect(byID[s[0].id!]?.participantID == priya.id && byID[s[0].id!]?.clusterLabel == "Speaker 1")
        #expect(byID[s[1].id!]?.participantID == cluster.id)
        #expect(byID[s[2].id!]?.participantID == nil)
        #expect(byID[s[3].id!]?.participantID == me.id)
    }

    @Test func echoFlagsAreReplacedNotAccumulated() async throws {
        let (store, meeting, s, _) = try await setup()
        let mic = s[3].id!
        try await store.setEchoDuplicates(meetingID: meeting.id, micSegmentIDs: [mic, s[0].id!])
        var rows = try await store.segments(meetingID: meeting.id)
        #expect(rows.filter(\.isEchoDuplicate).map(\.id) == [mic])  // system segment ids are never flagged
        try await store.setEchoDuplicates(meetingID: meeting.id, micSegmentIDs: [])
        rows = try await store.segments(meetingID: meeting.id)
        #expect(rows.filter(\.isEchoDuplicate).isEmpty)
    }

    @Test func suggestionMarksAnExistingCandidateOrCreatesOneButNeverTheUserOrAClusterRow() async throws {
        let (store, meeting, _, _) = try await setup()
        try await store.upsertParticipant(meetingID: meeting.id, name: "Priya Shah", source: .calendar)
        try await store.recordSpeakerSuggestion(meetingID: meeting.id, cluster: "Speaker 1", name: "Priya Shah")
        try await store.recordSpeakerSuggestion(meetingID: meeting.id, cluster: "Speaker 2", name: "Lee")
        try await store.recordSpeakerSuggestion(meetingID: meeting.id, cluster: "Speaker 3", name: "Mason")

        let participants = try await store.participants(meetingID: meeting.id)
        let priya = try #require(participants.first { $0.displayName == "Priya Shah" })
        #expect(priya.source == .calendar && priya.clusterLabel == "Speaker 1")
        let lee = try #require(participants.first { $0.displayName == "Lee" })
        #expect(lee.source == .llmSuggested && lee.clusterLabel == "Speaker 2")
        #expect(participants.first { $0.isMe }?.clusterLabel == nil)
    }
}
