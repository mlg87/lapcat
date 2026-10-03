import Foundation
import GRDB

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
            return try String.fetchAll(
                db, sql: "SELECT id FROM meeting WHERE status = 'processing' ORDER BY started_at")
        }
    }
}
