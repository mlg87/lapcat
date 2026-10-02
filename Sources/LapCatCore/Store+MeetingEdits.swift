import Foundation
import GRDB

// Targeted single-column writes for edits made in the meeting window. They do not rewrite the
// whole row (as `updateMeeting` does), so a concurrent pipeline update is never overwritten.

extension Store {
    public func renameMeeting(id: String, to title: String, now: Date = Date()) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET title = ?, updated_at = ? WHERE id = ?",
                arguments: [title, now.timeIntervalSince1970, id])
        }
    }

    public func setConsentConfirmed(meetingID: String, now: Date = Date()) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET consent_confirmed = 1, updated_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, meetingID])
        }
    }

    /// The meeting's participants, re-emitted after every committed change to `participant`.
    public func observeParticipants(meetingID: String) -> AsyncStream<[Participant]> {
        AsyncStream { continuation in
            let task = Task {
                let observation = ValueObservation.tracking { db in
                    try Participant.filter(Column("meeting_id") == meetingID).order(Column("id")).fetchAll(db)
                }
                do {
                    for try await value in observation.values(in: pool) { continuation.yield(value) }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The meeting's enhanced notes, newest version first, re-emitted after every change.
    public func observeEnhancedNotes(meetingID: String) -> AsyncStream<[EnhancedNote]> {
        AsyncStream { continuation in
            let task = Task {
                let observation = ValueObservation.tracking { db in
                    try EnhancedNote.filter(Column("meeting_id") == meetingID).order(Column("version").desc).fetchAll(db)
                }
                do {
                    for try await value in observation.values(in: pool) { continuation.yield(value) }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Accepts `suggestion`: the cluster participant's segments move to the suggested participant,
    /// the cluster row is deleted and the suggestion's `cluster_label` cleared. Returns the survivor.
    @discardableResult
    public func confirmSpeakerSuggestion(suggestedID: Int64, clusterID: Int64) async throws -> Participant {
        try await pool.write { db in
            guard var keep = try Participant.fetchOne(db, key: suggestedID) else { throw StoreError.notFound("participant \(suggestedID)") }
            guard let remove = try Participant.fetchOne(db, key: clusterID) else { throw StoreError.notFound("participant \(clusterID)") }
            guard keep.meetingID == remove.meetingID else { throw StoreError.participantsInDifferentMeetings }
            try db.execute(sql: "UPDATE segment SET participant_id = ? WHERE participant_id = ?", arguments: [suggestedID, clusterID])
            _ = try remove.delete(db)
            keep.clusterLabel = nil
            try keep.update(db)
            return keep
        }
    }

    /// Rejects a suggestion: an `llm_suggested` row is deleted, any other row only loses its `cluster_label`.
    public func dismissSpeakerSuggestion(suggestedID: Int64) async throws {
        try await pool.write { db in
            guard var participant = try Participant.fetchOne(db, key: suggestedID) else { return }
            if participant.source == .llmSuggested {
                _ = try participant.delete(db)
            } else {
                participant.clusterLabel = nil
                try participant.update(db)
            }
        }
    }
}
