import Foundation
import GRDB
import Testing
@testable import LapCatCore

struct StoreTests {
    private func makeStore() throws -> Store {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lapcat-tests-\(UUID().uuidString)")
        return try Store(databaseURL: dir.appendingPathComponent("lapcat.sqlite"))
    }

    private func segment(
        _ meetingID: String, _ channel: Channel, _ start: Int, _ text: String, participant: Int64? = nil,
        pass: SegmentPass = .final
    ) -> Segment {
        Segment(
            meetingID: meetingID, channel: channel, tStartMs: start, tEndMs: start + 1_000, text: text,
            participantID: participant, pass: pass)
    }

    private func segment(
        _ meetingID: String, _ start: Int, _ text: String, participant: Int64? = nil, pass: SegmentPass = .final
    ) -> Segment {
        segment(meetingID, .system, start, text, participant: participant, pass: pass)
    }

    @Test func migratorCreatesAllTables() async throws {
        let store = try makeStore()
        let tables = try await store.reader.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        let expected: Set<String> = [
            "meeting", "calendar_snapshot", "participant", "speaker_event", "segment", "raw_note", "enhanced_note",
            "template", "recipe", "chat_thread", "chat_message", "folder", "tag", "meeting_tag", "voiceprint",
            "audio_file", "fts_content",
        ]
        #expect(expected.isSubset(of: tables), "missing: \(expected.subtracting(tables))")
    }

    @Test func datesAreStoredAsUnixSeconds() async throws {
        let store = try makeStore()
        let m = try await store.createMeeting(title: "A", startedBy: .manual, now: Date(timeIntervalSince1970: 1_000))
        try await store.saveRawNote(meetingID: m.id, markdown: "x", now: Date(timeIntervalSince1970: 2_000))
        let stored: [Double] = try await store.reader.read { db in
            try Double.fetchAll(
                db, sql: "SELECT m.started_at FROM meeting m UNION ALL SELECT r.updated_at FROM raw_note r")
        }
        #expect(stored == [1_000, 2_000])
        #expect(try await store.meeting(id: m.id)?.startedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test func searchFindsReindexedSegmentWithHighlightedSnippet() async throws {
        let store = try makeStore()
        let meeting = try await store.createMeeting(title: "Sync", startedBy: .manual)
        let other = try await store.createMeeting(title: "Other", startedBy: .manual)
        let saved = try await store.appendSegments([
            segment(meeting.id, 0, "Let's talk about the weather"),
            segment(meeting.id, 2_000, "The pricing for next quarter is final"),
        ])
        try await store.appendSegments([segment(other.id, 0, "Nothing relevant here")])
        try await store.reindexFTS(meetingID: meeting.id)
        try await store.reindexFTS(meetingID: other.id)

        let hits = try await store.search(query: "pricing")
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.meetingID == meeting.id)
        #expect(hit.kind == .segment)
        #expect(hit.refID == String(try #require(saved[1].id)))
        #expect(hit.snippet.contains("<b>pricing</b>"))

        let prefix = try await store.search(query: "pric")
        #expect(prefix.map(\.refID) == [hit.refID])
    }

    @Test func malformedQueriesYieldNoHitsInsteadOfThrowing() async throws {
        let store = try makeStore()
        let meeting = try await store.createMeeting(title: "Sync", startedBy: .manual)
        try await store.appendSegments([segment(meeting.id, 0, "pricing discussion")])
        try await store.reindexFTS(meetingID: meeting.id)

        #expect(try await store.search(query: "\"").isEmpty)
        #expect(try await store.search(query: "   ").isEmpty)
        // An embedded quote is escaped, so the remaining text still matches.
        #expect(try await store.search(query: "\"pricing").count == 1)
    }

    @Test func reindexReplacesLiveRowsWithFinalAndSkipsVolatileAndEcho() async throws {
        let store = try makeStore()
        let meeting = try await store.createMeeting(title: "Sync", startedBy: .manual)
        try await store.appendSegments([segment(meeting.id, 0, "liveword", pass: .live)])
        try await store.replaceVolatileSegment(
            meetingID: meeting.id, channel: .mic, with: segment(meeting.id, .mic, 5_000, "volatileword", pass: .live))
        try await store.reindexFTS(meetingID: meeting.id)
        #expect(try await store.search(query: "liveword").count == 1)
        #expect(try await store.search(query: "volatileword").isEmpty)

        var echo = segment(meeting.id, .mic, 0, "echoword")
        echo.isEchoDuplicate = true
        try await store.appendSegments([segment(meeting.id, 0, "finalword"), echo])
        try await store.reindexFTS(meetingID: meeting.id)
        #expect(try await store.search(query: "liveword").isEmpty)
        #expect(try await store.search(query: "finalword").count == 1)
        #expect(try await store.search(query: "echoword").isEmpty)
    }

    @Test func renameParticipantAffectsOnlyThatMeeting() async throws {
        let store = try makeStore()
        let a = try await store.createMeeting(title: "A", startedBy: .manual)
        let b = try await store.createMeeting(title: "B", startedBy: .manual)
        let pa = try await store.upsertParticipant(meetingID: a.id, name: "Speaker 1", source: .cluster)
        let pb = try await store.upsertParticipant(meetingID: b.id, name: "Speaker 1", source: .cluster)
        try await store.appendSegments([
            segment(a.id, 0, "hi", participant: pa.id), segment(a.id, 2_000, "yo", participant: pa.id),
        ])
        try await store.appendSegments([segment(b.id, 0, "hey", participant: pb.id)])

        try await store.renameParticipant(id: try #require(pa.id), to: "Priya Shah")

        let namesA = try await store.participants(meetingID: a.id).map(\.displayName)
        let namesB = try await store.participants(meetingID: b.id).map(\.displayName)
        #expect(namesA == ["Priya Shah"])
        #expect(namesB == ["Speaker 1"])
        #expect(try await store.segments(meetingID: a.id).allSatisfy { $0.participantID == pa.id })
    }

    @Test func renameOntoAnExistingNameMergesTheTwo() async throws {
        let store = try makeStore()
        let m = try await store.createMeeting(title: "A", startedBy: .manual)
        let priya = try await store.upsertParticipant(meetingID: m.id, name: "Priya", source: .zoomAX)
        let cluster = try await store.upsertParticipant(meetingID: m.id, name: "Speaker 2", source: .cluster)
        try await store.appendSegments([segment(m.id, 0, "x", participant: cluster.id)])

        let survivor = try await store.renameParticipant(id: try #require(cluster.id), to: "Priya")

        #expect(survivor.id == priya.id)
        #expect(try await store.participants(meetingID: m.id).map(\.id) == [priya.id])
        #expect(try await store.segments(meetingID: m.id).first?.participantID == priya.id)
    }

    @Test func mergeParticipantsMovesSegmentsAndDeletesRemoved() async throws {
        let store = try makeStore()
        let m = try await store.createMeeting(title: "A", startedBy: .manual)
        let keep = try await store.upsertParticipant(meetingID: m.id, name: "Priya", source: .zoomAX)
        let remove = try await store.upsertParticipant(meetingID: m.id, name: "Speaker 1", source: .cluster)
        try await store.appendSegments([
            segment(m.id, 0, "one", participant: remove.id),
            segment(m.id, 2_000, "two", participant: keep.id),
        ])

        try await store.mergeParticipants(keep: try #require(keep.id), remove: try #require(remove.id))

        #expect(try await store.participants(meetingID: m.id).map(\.displayName) == ["Priya"])
        #expect(try await store.segments(meetingID: m.id).map(\.participantID) == [keep.id, keep.id])
    }

    @Test func mergeAcrossMeetingsIsRejected() async throws {
        let store = try makeStore()
        let a = try await store.createMeeting(title: "A", startedBy: .manual)
        let b = try await store.createMeeting(title: "B", startedBy: .manual)
        let pa = try await store.upsertParticipant(meetingID: a.id, name: "X", source: .manual)
        let pb = try await store.upsertParticipant(meetingID: b.id, name: "Y", source: .manual)
        await #expect(throws: StoreError.participantsInDifferentMeetings) {
            try await store.mergeParticipants(keep: try #require(pa.id), remove: try #require(pb.id))
        }
        #expect(try await store.participants(meetingID: b.id).count == 1)
    }

    @Test func insertEnhancedNoteKeepsNewestFiveVersions() async throws {
        let store = try makeStore()
        let m = try await store.createMeeting(title: "A", startedBy: .manual)
        let other = try await store.createMeeting(title: "B", startedBy: .manual)
        func note(_ meetingID: String, _ i: Int) -> EnhancedNote {
            EnhancedNote(
                meetingID: meetingID, templateID: "general", provider: "claude-cli", model: "sonnet", markdown: "v\(i)",
                basedOnPass: .live, createdAt: Date())
        }
        try await store.insertEnhancedNote(note(other.id, 0))
        for i in 1...7 { try await store.insertEnhancedNote(note(m.id, i)) }

        let notes = try await store.enhancedNotes(meetingID: m.id)
        #expect(notes.map(\.version) == [7, 6, 5, 4, 3])
        #expect(notes.map(\.markdown) == ["v7", "v6", "v5", "v4", "v3"])
        #expect(try await store.enhancedNotes(meetingID: other.id).map(\.version) == [1])
    }

    @Test func replaceVolatileSegmentKeepsOneVolatileRowPerChannel() async throws {
        let store = try makeStore()
        let m = try await store.createMeeting(title: "A", startedBy: .manual)
        try await store.appendSegments([segment(m.id, .mic, 0, "done", pass: .live)])
        try await store.replaceVolatileSegment(
            meetingID: m.id, channel: .mic, with: segment(m.id, .mic, 1_000, "hel", pass: .live))
        try await store.replaceVolatileSegment(
            meetingID: m.id, channel: .mic, with: segment(m.id, .mic, 1_000, "hello", pass: .live))
        try await store.replaceVolatileSegment(
            meetingID: m.id, channel: .system, with: segment(m.id, .system, 1_000, "them", pass: .live))

        var volatile = try await store.segments(meetingID: m.id).filter(\.isVolatile)
        #expect(volatile.map(\.text).sorted() == ["hello", "them"])

        try await store.replaceVolatileSegment(meetingID: m.id, channel: .mic, with: nil)
        volatile = try await store.segments(meetingID: m.id).filter(\.isVolatile)
        #expect(volatile.map(\.channel) == [.system])
        #expect(try await store.segments(meetingID: m.id).contains { $0.text == "done" && !$0.isVolatile })
    }

    @Test func updateSegmentTextPreservesFirstOriginal() async throws {
        let store = try makeStore()
        let m = try await store.createMeeting(title: "A", startedBy: .manual)
        let id = try #require(try await store.appendSegments([segment(m.id, 0, "teh text")]).first?.id)
        try await store.updateSegmentText(id: id, text: "the text")
        try await store.updateSegmentText(id: id, text: "the text!")
        let s = try #require(try await store.segments(meetingID: m.id).first)
        #expect(s.text == "the text!")
        #expect(s.textOriginal == "teh text")
        #expect(s.editedAt != nil)
    }

    @Test func recoveryFlipsRecordingToProcessingAndReturnsProcessingMeetings() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_000)
        let crashed = try await store.createMeeting(title: "Crashed", startedBy: .manual, now: start)
        let empty = try await store.createMeeting(title: "Empty", startedBy: .manual, now: start.addingTimeInterval(10))
        var midway = try await store.createMeeting(
            title: "Midway", startedBy: .manual, now: start.addingTimeInterval(20))
        midway.status = .processing
        midway.processingStep = "final_stt_system"
        try await store.updateMeeting(midway)
        var done = try await store.createMeeting(title: "Done", startedBy: .manual, now: start.addingTimeInterval(30))
        done.status = .ready
        try await store.updateMeeting(done)
        try await store.appendSegments([
            Segment(meetingID: crashed.id, channel: .mic, tStartMs: 0, tEndMs: 42_500, text: "a", pass: .live),
            Segment(meetingID: crashed.id, channel: .system, tStartMs: 1_000, tEndMs: 20_000, text: "b", pass: .live),
        ])

        let ids = try await store.recoverInterruptedMeetings(now: start.addingTimeInterval(100))

        #expect(ids == [crashed.id, empty.id, midway.id])
        let c = try #require(try await store.meeting(id: crashed.id))
        #expect(c.status == .processing)
        #expect(c.processingStep == nil)
        #expect(c.endedAt == start.addingTimeInterval(42.5))
        #expect(try await store.meeting(id: empty.id)?.endedAt == start.addingTimeInterval(10))
        #expect(try await store.meeting(id: midway.id)?.processingStep == "final_stt_system")
        #expect(try await store.meeting(id: done.id)?.status == .ready)
    }

    @Test func meetingFilterCombinesFolderStarAndPerson() async throws {
        let store = try makeStore()
        let folder = try await store.createFolder(name: "Customers")
        let a = try await store.createMeeting(title: "Acme pricing", startedBy: .manual)
        let b = try await store.createMeeting(title: "Standup", startedBy: .manual)
        try await store.setFolder(meetingID: a.id, folderID: folder.id)
        try await store.setStarred(meetingID: a.id, starred: true)
        try await store.upsertParticipant(meetingID: b.id, name: "Priya Shah", source: .calendar)

        #expect(
            try await store.meetings(filter: MeetingFilter(folderID: folder.id, starredOnly: true)).map(\.id) == [a.id])
        #expect(try await store.meetings(filter: MeetingFilter(personName: "priya")).map(\.id) == [b.id])
        #expect(try await store.meetings(filter: MeetingFilter(search: "acme")).map(\.id) == [a.id])

        try await store.deleteFolder(id: folder.id)
        #expect(try await store.meeting(id: a.id)?.folderID == nil)
    }

    @Test func audioPastRetentionOnlyListsExpiredMeetings() async throws {
        let store = try makeStore()
        let now = Date()
        var expired = try await store.createMeeting(title: "Old", startedBy: .manual)
        expired.audioRetainedUntil = now.addingTimeInterval(-86_400)
        try await store.updateMeeting(expired)
        var fresh = try await store.createMeeting(title: "New", startedBy: .manual)
        fresh.audioRetainedUntil = now.addingTimeInterval(86_400)
        try await store.updateMeeting(fresh)
        let forever = try await store.createMeeting(title: "Keep", startedBy: .manual)
        for m in [expired, fresh, forever] {
            try await store.saveAudioFile(AudioFile(meetingID: m.id, channel: .mic, path: "/tmp/\(m.id)/mic.aac"))
        }

        let past = try await store.audioFilesPastRetention(now: now)
        #expect(past.map(\.meetingID) == [expired.id])
        #expect(past.first?.codec == "aac-adts")

        try await store.deleteAudioFiles(meetingID: expired.id)
        #expect(try await store.audioFilesPastRetention(now: now).isEmpty)
        #expect(try await store.meeting(id: expired.id)?.audioRetainedUntil == nil)
    }

    @Test func chatThreadIsCreatedOncePerScope() async throws {
        let store = try makeStore()
        let m = try await store.createMeeting(title: "A", startedBy: .manual)
        let t1 = try await store.thread(for: .meeting, scopeRef: m.id)
        let t2 = try await store.thread(for: .meeting, scopeRef: m.id)
        let global = try await store.thread(for: .global)
        #expect(t1.id == t2.id)
        #expect(global.id != t1.id)
        #expect(try await store.thread(for: .global).id == global.id)

        try await store.appendChatMessage(ChatMessage(threadID: t1.id, role: .user, content: "q", createdAt: Date()))
        try await store.appendChatMessage(
            ChatMessage(threadID: t1.id, role: .assistant, content: "a", createdAt: Date()))
        #expect(try await store.messages(threadID: t1.id).map(\.role) == [.user, .assistant])
    }
}
