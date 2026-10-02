import Foundation
import GRDB

extension Store {
    /// The meeting's segments (both passes, volatile rows included), re-emitted after every
    /// committed change to the `segment` table for that meeting. Ends when the consumer stops.
    public func observeSegments(meetingID: String) -> AsyncStream<[Segment]> {
        observe { db in
            try Segment.filter(Column("meeting_id") == meetingID)
                .order(Column("t_start_ms"), Column("id"))
                .fetchAll(db)
        }
    }

    public func observeMeeting(id: String) -> AsyncStream<Meeting?> {
        observe { db in try Meeting.fetchOne(db, key: id) }
    }

    public func observeMeetings(filter: MeetingFilter = MeetingFilter()) -> AsyncStream<[Meeting]> {
        // The filter query is async (FTS), so it is re-run on every committed change to `meeting`:
        // ValueObservation without removeDuplicates emits after each transaction touching the table.
        let changes: AsyncStream<Int> = observe { db in try Meeting.fetchCount(db) }
        return AsyncStream { continuation in
            let task = Task {
                for await _ in changes {
                    if let meetings = try? await self.meetings(filter: filter) { continuation.yield(meetings) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func observe<Value: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> Value) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in ValueObservation.tracking(fetch).values(in: pool) {
                        continuation.yield(value)
                    }
                } catch {
                    // Cancellation or a database error ends the stream.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
