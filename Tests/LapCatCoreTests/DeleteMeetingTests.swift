import Foundation
import GRDB
import Testing

@testable import LapCatCore

@Suite struct DeleteMeetingTests {
    /// Tables whose rows belong to one meeting, with the column that names it.
    private static let meetingTables = [
        ("segment", "meeting_id"), ("participant", "meeting_id"), ("speaker_event", "meeting_id"),
        ("raw_note", "meeting_id"), ("enhanced_note", "meeting_id"), ("meeting_tag", "meeting_id"),
        ("audio_file", "meeting_id"), ("calendar_snapshot", "meeting_id"), ("fts_content", "meeting_id"),
        ("chat_thread", "scope_ref"),
    ]

    /// A finished meeting with a row in every table that belongs to a meeting.
    private func populatedMeeting(_ store: Store, title: String) async throws -> Meeting {
        var meeting = try await store.createMeeting(title: title, startedBy: .manual)
        meeting.status = .ready
        try await store.updateMeeting(meeting)
        let participant = try await store.upsertParticipant(meetingID: meeting.id, name: "Priya", source: .zoomAX)
        try await store.appendSegments([
            Segment(
                meetingID: meeting.id, channel: .system, tStartMs: 0, tEndMs: 1_000, text: "\(title) pricing",
                participantID: participant.id, pass: .final)
        ])
        try await store.saveRawNote(meetingID: meeting.id, markdown: "notes")
        try await store.insertEnhancedNote(
            EnhancedNote(
                meetingID: meeting.id, templateID: "general", provider: "claude-cli", model: "sonnet",
                markdown: "summary", basedOnPass: .final, createdAt: Date()))
        try await store.setTags(meetingID: meeting.id, ["customer"])
        try await store.saveAudioFile(AudioFile(meetingID: meeting.id, channel: .mic, path: "/tmp/mic.aac"))
        let id = meeting.id
        try await store.pool.write { db in
            try CalendarSnapshot(meetingID: id).insert(db)
            try db.execute(
                sql: """
                    INSERT INTO speaker_event(meeting_id, t_start_ms, display_name, source)
                    VALUES (?, 0, 'Priya', 'zoom_ax')
                    """,
                arguments: [id])
        }
        let thread = try await store.thread(for: .meeting, scopeRef: meeting.id)
        try await store.appendChatMessage(
            ChatMessage(threadID: thread.id, role: .user, content: "question", createdAt: Date()))
        try await store.reindexFTS(meetingID: meeting.id)
        return meeting
    }

    private func rowCounts(_ store: Store, meetingID: String) async throws -> [String: Int] {
        try await store.reader.read { db in
            var counts: [String: Int] = [:]
            for (table, column) in Self.meetingTables {
                counts[table] = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = ?", arguments: [meetingID])
            }
            return counts
        }
    }

    @Test func deletesEveryRowOfTheMeetingAndKeepsOtherMeetings() async throws {
        let (store, _) = try makeTempStore()
        let doomed = try await populatedMeeting(store, title: "Doomed")
        let kept = try await populatedMeeting(store, title: "Kept")
        let global = try await store.thread(for: .global)
        try await store.appendChatMessage(
            ChatMessage(threadID: global.id, role: .user, content: "across meetings", createdAt: Date()))
        #expect(try await rowCounts(store, meetingID: doomed.id).values.allSatisfy { $0 > 0 })

        try await store.deleteMeeting(id: doomed.id)

        #expect(try await store.meeting(id: doomed.id) == nil)
        #expect(try await rowCounts(store, meetingID: doomed.id).values.allSatisfy { $0 == 0 })
        #expect(try await rowCounts(store, meetingID: kept.id).values.allSatisfy { $0 > 0 })
        #expect(try await store.messages(threadID: global.id).count == 1)
        #expect(try await store.search(query: "pricing").map(\.meetingID) == [kept.id])
        #expect(try await store.tags().map(\.name) == ["customer"])
    }

    @Test(arguments: [MeetingStatus.recording, .processing])
    func refusesAMeetingThatIsStillBeingWritten(status: MeetingStatus) async throws {
        let (store, _) = try makeTempStore()
        var meeting = try await populatedMeeting(store, title: "Busy")
        meeting.status = status
        try await store.updateMeeting(meeting)

        await #expect(throws: StoreError.meetingBusy(meeting.id)) {
            try await store.deleteMeeting(id: meeting.id)
        }
        #expect(try await store.meeting(id: meeting.id) != nil)
        #expect(try await rowCounts(store, meetingID: meeting.id).values.allSatisfy { $0 > 0 })
    }

    @Test func deletesAMeetingWhoseProcessingFailed() async throws {
        let (store, _) = try makeTempStore()
        var meeting = try await populatedMeeting(store, title: "Failed")
        meeting.status = .error
        try await store.updateMeeting(meeting)

        try await store.deleteMeeting(id: meeting.id)

        #expect(try await store.meeting(id: meeting.id) == nil)
    }

    @Test func unknownMeetingIsNotFound() async throws {
        let (store, _) = try makeTempStore()
        await #expect(throws: StoreError.notFound("meeting missing")) {
            try await store.deleteMeeting(id: "missing")
        }
    }
}
