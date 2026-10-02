import Foundation
import GRDB

extension Store {
    /// Folders in sidebar order, re-emitted after every committed change to `folder`.
    public func observeFolders() -> AsyncStream<[Folder]> {
        observeValues { db in try Folder.order(Column("sort_order"), Column("name")).fetchAll(db) }
    }

    /// The meeting's tag names (alphabetical), re-emitted after changes to `tag` or `meeting_tag`.
    public func observeTagNames(meetingID: String) -> AsyncStream<[String]> {
        observeValues { db in
            try String.fetchAll(
                db,
                sql: "SELECT tag.name FROM tag JOIN meeting_tag ON meeting_tag.tag_id = tag.id WHERE meeting_tag.meeting_id = ? ORDER BY tag.name",
                arguments: [meetingID])
        }
    }

    private func observeValues<Value: Sendable & Equatable>(_ fetch: @escaping @Sendable (Database) throws -> Value) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in ValueObservation.tracking(fetch).removeDuplicates().values(in: pool) {
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
