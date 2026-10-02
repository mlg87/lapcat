import Foundation
import GRDB

/// Carries user work done on the live transcript (text edits, speaker assignments) onto the
/// final-pass segments that replace it.
public enum LiveMerge {
    public struct Update: Equatable, Sendable {
        public var finalID: Int64
        /// Edited live text, with the final pass's own text kept as `textOriginal`.
        public var text: String?
        public var textOriginal: String?
        public var participantID: Int64?
    }

    /// For each live segment the user edited or assigned, the same-channel final segment with the
    /// largest overlap (at least 1 ms) receives the edit/assignment. One final segment takes the
    /// edit with the most overlap when several live segments map to it.
    public static func plan(live: [Segment], final: [Segment]) -> [Update] {
        var best: [Int64: (overlap: Int, update: Update)] = [:]
        for segment in live where segment.editedAt != nil || segment.participantID != nil {
            var target: (id: Int64, text: String, overlap: Int)?
            for candidate in final where candidate.channel == segment.channel {
                guard let id = candidate.id else { continue }
                let overlap = min(segment.tEndMs, candidate.tEndMs) - max(segment.tStartMs, candidate.tStartMs)
                if overlap >= 1, overlap > (target?.overlap ?? 0) { target = (id, candidate.text, overlap) }
            }
            guard let target else { continue }
            var update = Update(finalID: target.id)
            if segment.editedAt != nil {
                update.text = segment.text
                update.textOriginal = target.text
            }
            update.participantID = segment.participantID
            if let existing = best[target.id], existing.overlap >= target.overlap {
                // Keep the stronger match's edit; still take a participant it lacks.
                var merged = existing.update
                if merged.participantID == nil { merged.participantID = update.participantID }
                if merged.text == nil, update.text != nil { (merged.text, merged.textOriginal) = (update.text, update.textOriginal) }
                best[target.id] = (existing.overlap, merged)
            } else {
                if let existing = best[target.id]?.update {
                    if update.participantID == nil { update.participantID = existing.participantID }
                    if update.text == nil { (update.text, update.textOriginal) = (existing.text, existing.textOriginal) }
                }
                best[target.id] = (target.overlap, update)
            }
        }
        return best.values.map(\.update).sorted { $0.finalID < $1.finalID }
    }
}

extension Store {
    /// Replaces the channel's final-pass segments in one transaction (re-runs are idempotent).
    @discardableResult
    public func replaceFinalSegments(meetingID: String, channel: Channel, with segments: [Segment]) async throws -> [Segment] {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM segment WHERE meeting_id = ? AND channel = ? AND pass = 'final'",
                arguments: [meetingID, channel.rawValue])
            return try segments.map { segment in
                var segment = segment
                segment.id = nil
                segment.meetingID = meetingID
                segment.channel = channel
                segment.pass = .final
                segment.isVolatile = false
                try segment.insert(db)
                return segment
            }
        }
    }

    /// Applies `LiveMerge.plan` to the final segments, then deletes every live row of the meeting.
    /// Does nothing when the meeting has no final segments (live text stays the transcript).
    public func mergeLiveIntoFinal(meetingID: String, now: Date = Date()) async throws {
        try await pool.write { db in
            let all = try Segment.filter(Column("meeting_id") == meetingID).fetchAll(db)
            let final = all.filter { $0.pass == .final }
            guard !final.isEmpty else { return }
            let live = all.filter { $0.pass == .live && !$0.isVolatile }
            for update in LiveMerge.plan(live: live, final: final) {
                if let text = update.text {
                    try db.execute(
                        sql: "UPDATE segment SET text = ?, text_original = ?, edited_at = ? WHERE id = ?",
                        arguments: [text, update.textOriginal, now.timeIntervalSince1970, update.finalID])
                }
                if let participant = update.participantID {
                    try db.execute(
                        sql: "UPDATE segment SET participant_id = ? WHERE id = ?",
                        arguments: [participant, update.finalID])
                }
            }
            try db.execute(sql: "DELETE FROM segment WHERE meeting_id = ? AND pass = 'live'", arguments: [meetingID])
        }
    }

    /// Records the step about to run (crash recovery resumes from it).
    public func setProcessingStep(meetingID: String, step: String?, now: Date = Date()) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET processing_step = ?, updated_at = ? WHERE id = ?",
                arguments: [step, now.timeIntervalSince1970, meetingID])
        }
    }

    public func setMeetingStatus(
        meetingID: String, status: MeetingStatus, errorMessage: String? = nil, now: Date = Date()
    ) async throws {
        try await pool.write { db in
            let step: String? = status == .ready ? nil : try String.fetchOne(
                db, sql: "SELECT processing_step FROM meeting WHERE id = ?", arguments: [meetingID])
            try db.execute(
                sql: "UPDATE meeting SET status = ?, error_message = ?, processing_step = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, errorMessage, step, now.timeIntervalSince1970, meetingID])
        }
    }
}
