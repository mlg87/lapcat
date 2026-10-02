import Foundation
import GRDB

public enum StoreError: Error, Equatable {
    case notFound(String)
    case participantsInDifferentMeetings
}

public struct MeetingFilter: Sendable, Equatable {
    /// Matches the title (substring) or any indexed content (FTS prefix match).
    public var search: String?
    public var folderID: String?
    public var starredOnly: Bool
    public var dateRange: ClosedRange<Date>?
    /// Substring of a participant's display name.
    public var personName: String?

    public init(search: String? = nil, folderID: String? = nil, starredOnly: Bool = false, dateRange: ClosedRange<Date>? = nil, personName: String? = nil) {
        self.search = search
        self.folderID = folderID
        self.starredOnly = starredOnly
        self.dateRange = dateRange
        self.personName = personName
    }
}

// MARK: - Meetings

extension Store {
    public func createMeeting(
        title: String,
        startedBy: MeetingStartedBy,
        sourceApp: String = "other",
        bundleID: String? = nil,
        pid: Int32? = nil,
        now: Date = Date()
    ) async throws -> Meeting {
        let meeting = Meeting(
            title: title, startedAt: now, sourceApp: sourceApp, sourceBundleID: bundleID,
            sourcePID: pid, startedBy: startedBy, createdAt: now, updatedAt: now)
        try await pool.write { db in try meeting.insert(db) }
        return meeting
    }

    /// Persists every column of `meeting` and bumps `updated_at`.
    @discardableResult
    public func updateMeeting(_ meeting: Meeting, now: Date = Date()) async throws -> Meeting {
        var meeting = meeting
        meeting.updatedAt = now
        try await pool.write { [meeting] db in try meeting.update(db) }
        return meeting
    }

    public func meeting(id: String) async throws -> Meeting? {
        try await pool.read { db in try Meeting.fetchOne(db, key: id) }
    }

    /// Newest first.
    public func meetings(filter: MeetingFilter = MeetingFilter()) async throws -> [Meeting] {
        var sql = "SELECT * FROM meeting WHERE 1"
        var args = StatementArguments()
        if let folderID = filter.folderID {
            sql += " AND folder_id = ?"
            args += [folderID]
        }
        if filter.starredOnly { sql += " AND starred = 1" }
        if let range = filter.dateRange {
            sql += " AND started_at >= ? AND started_at <= ?"
            args += [range.lowerBound.timeIntervalSince1970, range.upperBound.timeIntervalSince1970]
        }
        if let person = filter.personName?.trimmingCharacters(in: .whitespaces), !person.isEmpty {
            sql += " AND id IN (SELECT meeting_id FROM participant WHERE display_name LIKE ?)"
            args += ["%\(person)%"]
        }
        if let search = filter.search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            if let match = Self.ftsQuery(search) {
                sql += " AND (title LIKE ? OR id IN (SELECT meeting_id FROM fts_content WHERE fts_content MATCH ?))"
                args += ["%\(search)%", match]
            } else {
                sql += " AND title LIKE ?"
                args += ["%\(search)%"]
            }
        }
        sql += " ORDER BY started_at DESC"
        let (finalSQL, finalArgs) = (sql, args)
        return try await pool.read { db in
            try Meeting.fetchAll(db, sql: finalSQL, arguments: finalArgs)
        }
    }

    public func setStarred(meetingID: String, starred: Bool, now: Date = Date()) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET starred = ?, updated_at = ? WHERE id = ?",
                arguments: [starred, now.timeIntervalSince1970, meetingID])
        }
    }

    public func setFolder(meetingID: String, folderID: String?, now: Date = Date()) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET folder_id = ?, updated_at = ? WHERE id = ?",
                arguments: [folderID, now.timeIntervalSince1970, meetingID])
        }
    }

    public func saveCalendarSnapshot(_ snapshot: CalendarSnapshot) async throws {
        try await pool.write { db in try snapshot.insert(db, onConflict: .replace) }
    }

    public func calendarSnapshot(meetingID: String) async throws -> CalendarSnapshot? {
        try await pool.read { db in try CalendarSnapshot.fetchOne(db, key: meetingID) }
    }
}

// MARK: - Segments

extension Store {
    /// Inserts segments and returns them with their row ids.
    @discardableResult
    public func appendSegments(_ segments: [Segment]) async throws -> [Segment] {
        try await pool.write { db in
            try segments.map { segment in
                var segment = segment
                try segment.insert(db)
                return segment
            }
        }
    }

    /// Deletes the channel's volatile (hypothesis) row, then inserts `segment` as the new one.
    /// Passing nil only clears it. At most one volatile row per meeting and channel exists.
    @discardableResult
    public func replaceVolatileSegment(meetingID: String, channel: Channel, with segment: Segment?) async throws -> Segment? {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM segment WHERE meeting_id = ? AND channel = ? AND is_volatile = 1",
                arguments: [meetingID, channel.rawValue])
            guard var segment else { return nil }
            segment.id = nil
            segment.meetingID = meetingID
            segment.channel = channel
            segment.isVolatile = true
            try segment.insert(db)
            return segment
        }
    }

    /// Segments ordered by start time; `pass == nil` returns both passes.
    public func segments(meetingID: String, pass: SegmentPass? = nil) async throws -> [Segment] {
        try await pool.read { db in
            var request = Segment.filter(Column("meeting_id") == meetingID)
            if let pass { request = request.filter(Column("pass") == pass.rawValue) }
            return try request.order(Column("t_start_ms"), Column("id")).fetchAll(db)
        }
    }

    /// User edit: keeps the first transcribed text in `text_original`.
    public func updateSegmentText(id: Int64, text: String, now: Date = Date()) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE segment SET text_original = COALESCE(text_original, text), text = ?, edited_at = ?
                    WHERE id = ?
                    """,
                arguments: [text, now.timeIntervalSince1970, id])
        }
    }

    public func assignSegment(id: Int64, participantID: Int64?) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE segment SET participant_id = ? WHERE id = ?", arguments: [participantID, id])
        }
    }
}

// MARK: - Participants and speaker events

extension Store {
    /// Returns the participant named `name` in the meeting, creating it if absent.
    @discardableResult
    public func upsertParticipant(
        meetingID: String, name: String, source: ParticipantSource, email: String? = nil, isMe: Bool = false
    ) async throws -> Participant {
        try await pool.write { db in
            if var existing = try Participant
                .filter(Column("meeting_id") == meetingID && Column("display_name") == name)
                .fetchOne(db)
            {
                var changed = false
                if existing.email == nil, let email { existing.email = email; changed = true }
                if isMe, !existing.isMe { existing.isMe = true; changed = true }
                if changed { try existing.update(db) }
                return existing
            }
            var participant = Participant(meetingID: meetingID, displayName: name, email: email, source: source, isMe: isMe)
            try participant.insert(db)
            return participant
        }
    }

    public func participants(meetingID: String) async throws -> [Participant] {
        try await pool.read { db in
            try Participant.filter(Column("meeting_id") == meetingID).order(Column("id")).fetchAll(db)
        }
    }

    /// Renames meeting-wide. If another participant of the same meeting already has `name`,
    /// the two are merged into that one. Returns the surviving participant.
    @discardableResult
    public func renameParticipant(id: Int64, to name: String) async throws -> Participant {
        try await pool.write { db in
            guard var participant = try Participant.fetchOne(db, key: id) else { throw StoreError.notFound("participant \(id)") }
            if let clash = try Participant
                .filter(Column("meeting_id") == participant.meetingID && Column("display_name") == name && Column("id") != id)
                .fetchOne(db)
            {
                return try Self.merge(db, keep: clash, remove: participant)
            }
            participant.displayName = name
            try participant.update(db)
            return participant
        }
    }

    /// Reassigns `remove`'s segments to `keep`, then deletes `remove`.
    @discardableResult
    public func mergeParticipants(keep keepID: Int64, remove removeID: Int64) async throws -> Participant {
        try await pool.write { db in
            guard let keep = try Participant.fetchOne(db, key: keepID) else { throw StoreError.notFound("participant \(keepID)") }
            guard let remove = try Participant.fetchOne(db, key: removeID) else { throw StoreError.notFound("participant \(removeID)") }
            return try Self.merge(db, keep: keep, remove: remove)
        }
    }

    private static func merge(_ db: Database, keep: Participant, remove: Participant) throws -> Participant {
        guard keep.id != remove.id else { return keep }
        guard keep.meetingID == remove.meetingID else { throw StoreError.participantsInDifferentMeetings }
        try db.execute(sql: "UPDATE segment SET participant_id = ? WHERE participant_id = ?", arguments: [keep.id, remove.id])
        _ = try remove.delete(db)
        var keep = keep
        if remove.isMe, !keep.isMe {
            keep.isMe = true
            try keep.update(db)
        }
        return keep
    }

    @discardableResult
    public func appendSpeakerEvent(meetingID: String, displayName: String, source: SpeakerEventSource, tStartMs: Int) async throws -> SpeakerEvent {
        try await pool.write { db in
            var event = SpeakerEvent(meetingID: meetingID, tStartMs: tStartMs, displayName: displayName, source: source)
            try event.insert(db)
            return event
        }
    }

    public func closeSpeakerEvent(id: Int64, tEndMs: Int) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE speaker_event SET t_end_ms = ? WHERE id = ?", arguments: [tEndMs, id])
        }
    }

    public func speakerEvents(meetingID: String) async throws -> [SpeakerEvent] {
        try await pool.read { db in
            try SpeakerEvent.filter(Column("meeting_id") == meetingID).order(Column("t_start_ms"), Column("id")).fetchAll(db)
        }
    }
}

// MARK: - Notes, templates, recipes

extension Store {
    public func saveRawNote(meetingID: String, markdown: String, now: Date = Date()) async throws {
        try await pool.write { db in
            try RawNote(meetingID: meetingID, markdown: markdown, updatedAt: now).insert(db, onConflict: .replace)
        }
    }

    public func rawNote(meetingID: String) async throws -> RawNote? {
        try await pool.read { db in try RawNote.fetchOne(db, key: meetingID) }
    }

    /// Inserts `note` as version max+1 (its `version` is ignored) and keeps only the newest 5 versions.
    @discardableResult
    public func insertEnhancedNote(_ note: EnhancedNote) async throws -> EnhancedNote {
        try await pool.write { db in
            let latest = try Int.fetchOne(
                db, sql: "SELECT MAX(version) FROM enhanced_note WHERE meeting_id = ?", arguments: [note.meetingID]) ?? 0
            var note = note
            note.id = nil
            note.version = latest + 1
            try note.insert(db)
            try db.execute(
                sql: "DELETE FROM enhanced_note WHERE meeting_id = ? AND version <= ?",
                arguments: [note.meetingID, note.version - Self.enhancedNoteVersionsKept])
            return note
        }
    }

    static let enhancedNoteVersionsKept = 5

    /// Newest version first.
    public func enhancedNotes(meetingID: String) async throws -> [EnhancedNote] {
        try await pool.read { db in
            try EnhancedNote.filter(Column("meeting_id") == meetingID).order(Column("version").desc).fetchAll(db)
        }
    }

    /// Built-ins first, then by name.
    public func templates() async throws -> [Template] {
        try await pool.read { db in
            try Template.order(Column("is_builtin").desc, Column("name")).fetchAll(db)
        }
    }

    public func upsertTemplate(_ template: Template) async throws {
        try await pool.write { db in try template.insert(db, onConflict: .replace) }
    }

    /// Built-in templates are never deleted.
    public func deleteCustomTemplate(id: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM template WHERE id = ? AND is_builtin = 0", arguments: [id])
        }
    }

    public func recipes() async throws -> [Recipe] {
        try await pool.read { db in
            try Recipe.order(Column("is_builtin").desc, Column("name")).fetchAll(db)
        }
    }

    public func upsertRecipe(_ recipe: Recipe) async throws {
        try await pool.write { db in try recipe.insert(db, onConflict: .replace) }
    }

    public func deleteCustomRecipe(id: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM recipe WHERE id = ? AND is_builtin = 0", arguments: [id])
        }
    }
}

// MARK: - Chat

extension Store {
    /// The thread for `scope`/`scopeRef`, created on first use.
    public func thread(for scope: ChatScope, scopeRef: String? = nil, now: Date = Date()) async throws -> ChatThread {
        try await pool.write { db in
            if let existing = try ChatThread.fetchOne(
                db, sql: "SELECT * FROM chat_thread WHERE scope = ? AND scope_ref IS ? ORDER BY created_at LIMIT 1",
                arguments: [scope.rawValue, scopeRef])
            {
                return existing
            }
            let thread = ChatThread(scope: scope, scopeRef: scopeRef, createdAt: now)
            try thread.insert(db)
            return thread
        }
    }

    @discardableResult
    public func appendChatMessage(_ message: ChatMessage) async throws -> ChatMessage {
        try await pool.write { db in
            var message = message
            message.id = nil
            try message.insert(db)
            return message
        }
    }

    /// Oldest first.
    public func messages(threadID: String) async throws -> [ChatMessage] {
        try await pool.read { db in
            try ChatMessage.filter(Column("thread_id") == threadID).order(Column("id")).fetchAll(db)
        }
    }
}

// MARK: - Folders and tags

extension Store {
    public func folders() async throws -> [Folder] {
        try await pool.read { db in try Folder.order(Column("sort_order"), Column("name")).fetchAll(db) }
    }

    /// Appends the folder at the end of the sort order.
    public func createFolder(name: String) async throws -> Folder {
        try await pool.write { db in
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM folder") ?? -1) + 1
            let folder = Folder(name: name, sortOrder: next)
            try folder.insert(db)
            return folder
        }
    }

    public func renameFolder(id: String, to name: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE folder SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    /// Meetings in the folder keep existing with `folder_id = NULL`.
    public func deleteFolder(id: String) async throws {
        try await pool.write { db in _ = try Folder.deleteOne(db, key: id) }
    }

    public func tags() async throws -> [Tag] {
        try await pool.read { db in try Tag.order(Column("name")).fetchAll(db) }
    }

    public func tags(meetingID: String) async throws -> [Tag] {
        try await pool.read { db in
            try Tag.fetchAll(
                db,
                sql: "SELECT tag.* FROM tag JOIN meeting_tag ON meeting_tag.tag_id = tag.id WHERE meeting_tag.meeting_id = ? ORDER BY tag.name",
                arguments: [meetingID])
        }
    }

    /// Replaces the meeting's tags with `names` (trimmed, empty and duplicate names dropped), creating tags as needed.
    public func setTags(meetingID: String, _ names: [String]) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM meeting_tag WHERE meeting_id = ?", arguments: [meetingID])
            var seen = Set<String>()
            for raw in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                let tag: Tag
                if let existing = try Tag.filter(Column("name") == name).fetchOne(db) {
                    tag = existing
                } else {
                    tag = Tag(name: name)
                    try tag.insert(db)
                }
                try MeetingTag(meetingID: meetingID, tagID: tag.id).insert(db)
            }
        }
    }
}

// MARK: - Audio files and retention

extension Store {
    public func saveAudioFile(_ file: AudioFile) async throws {
        try await pool.write { db in try file.insert(db, onConflict: .replace) }
    }

    public func audioFiles(meetingID: String) async throws -> [AudioFile] {
        try await pool.read { db in
            try AudioFile.filter(Column("meeting_id") == meetingID).order(Column("channel")).fetchAll(db)
        }
    }

    /// Removes the meeting's `audio_file` rows and clears `audio_retained_until` (files are the caller's job).
    public func deleteAudioFiles(meetingID: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM audio_file WHERE meeting_id = ?", arguments: [meetingID])
            try db.execute(sql: "UPDATE meeting SET audio_retained_until = NULL WHERE id = ?", arguments: [meetingID])
        }
    }

    /// Audio of meetings whose `audio_retained_until` is at or before `now`.
    public func audioFilesPastRetention(now: Date = Date()) async throws -> [AudioFile] {
        try await pool.read { db in
            try AudioFile.fetchAll(
                db,
                sql: """
                    SELECT audio_file.* FROM audio_file JOIN meeting ON meeting.id = audio_file.meeting_id
                    WHERE meeting.audio_retained_until IS NOT NULL AND meeting.audio_retained_until <= ?
                    ORDER BY audio_file.meeting_id, audio_file.channel
                    """,
                arguments: [now.timeIntervalSince1970])
        }
    }
}

// MARK: - Crash recovery

extension Store {
    /// Launch recovery (NFR-R2). Meetings left in `recording` by a crash become `processing`, with
    /// `ended_at` = start + last segment end (or the start when no segment exists) and `processing_step`
    /// cleared. Returns the ids of every `processing` meeting, oldest first, to enqueue for post-processing;
    /// each resumes from its `processing_step`.
    public func recoverInterruptedMeetings(now: Date = Date()) async throws -> [String] {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE meeting SET
                      status = 'processing',
                      processing_step = NULL,
                      ended_at = started_at + COALESCE(
                        (SELECT MAX(t_end_ms) FROM segment WHERE segment.meeting_id = meeting.id), 0) / 1000.0,
                      updated_at = ?
                    WHERE status = 'recording'
                    """,
                arguments: [now.timeIntervalSince1970])
            return try String.fetchAll(db, sql: "SELECT id FROM meeting WHERE status = 'processing' ORDER BY started_at")
        }
    }
}
