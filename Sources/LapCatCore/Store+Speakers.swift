import Foundation
import GRDB

/// One segment's speaker, as decided by name mapping (diarization + platform speaker events).
public struct SpeakerAssignmentRow: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The user (mic channel): the meeting's `is_me` participant.
        case me
        /// A real name from the meeting platform (Zoom/Meet accessibility).
        case named(String)
        /// An unnamed diarization cluster, `Speaker N`.
        case cluster(String)
        /// No speaker evidence.
        case unassigned
    }

    public var segmentID: Int64
    public var kind: Kind
    /// Diarization cluster written to `segment.cluster_label` (also for named segments).
    public var cluster: String?

    public init(segmentID: Int64, kind: Kind, cluster: String?) {
        self.segmentID = segmentID
        self.kind = kind
        self.cluster = cluster
    }
}

extension Store {
    /// Writes `participant_id` and `cluster_label` for the given segments in one transaction,
    /// creating participants as needed: named speakers with `namedSource`, clusters as
    /// `source='cluster'` rows labelled with their cluster. Re-running with the same rows is a no-op.
    public func applySpeakerAssignments(
        meetingID: String, rows: [SpeakerAssignmentRow], namedSource: ParticipantSource
    ) async throws {
        try await pool.write { db in
            var ids: [String: Int64] = [:]
            func participantID(name: String, source: ParticipantSource, cluster: String?) throws -> Int64 {
                if let id = ids[name] { return id }
                if let existing = try Participant
                    .filter(Column("meeting_id") == meetingID && Column("display_name") == name)
                    .fetchOne(db), let id = existing.id
                {
                    ids[name] = id
                    return id
                }
                var participant = Participant(meetingID: meetingID, displayName: name, source: source, clusterLabel: cluster)
                try participant.insert(db)
                ids[name] = participant.id!
                return participant.id!
            }
            let meID = try Int64.fetchOne(
                db, sql: "SELECT id FROM participant WHERE meeting_id = ? AND is_me = 1 ORDER BY id LIMIT 1",
                arguments: [meetingID])

            for row in rows {
                let participant: Int64?
                switch row.kind {
                case .me: participant = meID
                case .named(let name): participant = try participantID(name: name, source: namedSource, cluster: nil)
                case .cluster(let label): participant = try participantID(name: label, source: .cluster, cluster: label)
                case .unassigned: participant = nil
                }
                try db.execute(
                    sql: "UPDATE segment SET participant_id = ?, cluster_label = ? WHERE id = ? AND meeting_id = ?",
                    arguments: [participant, row.cluster, row.segmentID, meetingID])
            }
        }
    }

    /// Flags exactly `micSegmentIDs` as echo duplicates among the meeting's mic segments.
    public func setEchoDuplicates(meetingID: String, micSegmentIDs: [Int64]) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE segment SET is_echo_duplicate = 0 WHERE meeting_id = ? AND channel = 'mic'",
                arguments: [meetingID])
            for id in micSegmentIDs {
                try db.execute(
                    sql: "UPDATE segment SET is_echo_duplicate = 1 WHERE id = ? AND meeting_id = ? AND channel = 'mic'",
                    arguments: [id, meetingID])
            }
        }
    }

    /// Records "`cluster` might be `name`": the participant called `name` gets `cluster_label = cluster`
    /// (created with `source='llm_suggested'` when no such participant exists). Nothing is reassigned;
    /// the user confirms by merging the cluster participant into it.
    public func recordSpeakerSuggestion(meetingID: String, cluster: String, name: String) async throws {
        try await pool.write { db in
            if var existing = try Participant
                .filter(Column("meeting_id") == meetingID && Column("display_name") == name)
                .fetchOne(db)
            {
                guard existing.source != .cluster, !existing.isMe else { return }
                existing.clusterLabel = cluster
                try existing.update(db)
            } else {
                var participant = Participant(meetingID: meetingID, displayName: name, source: .llmSuggested, clusterLabel: cluster)
                try participant.insert(db)
            }
        }
    }
}
