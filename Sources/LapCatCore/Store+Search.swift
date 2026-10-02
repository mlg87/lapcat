import Foundation
import GRDB

public struct SearchHit: Sendable, Hashable {
    public var meetingID: String
    public var kind: SearchKind
    /// Segment id, enhanced-note id or participant id; the meeting id for `raw` and `title`.
    public var refID: String
    /// Match context with hits wrapped in `<b>…</b>`.
    public var snippet: String
    /// bm25 score: lower is better.
    public var rank: Double
}

extension Store {
    /// Rebuilds the meeting's `fts_content` rows: transcript segments (final pass if any exist, else live;
    /// volatile and echo duplicates excluded), raw note, newest enhanced note, title and participants.
    public func reindexFTS(meetingID: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM fts_content WHERE meeting_id = ?", arguments: [meetingID])
            guard let meeting = try Meeting.fetchOne(db, key: meetingID) else { return }

            func add(_ text: String, _ kind: SearchKind, _ ref: String) throws {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                try db.execute(
                    sql: "INSERT INTO fts_content(text, meeting_id, kind, ref_id) VALUES (?, ?, ?, ?)",
                    arguments: [text, meetingID, kind.rawValue, ref])
            }

            let hasFinal = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM segment WHERE meeting_id = ? AND pass = 'final')",
                arguments: [meetingID]) ?? false
            let pass: SegmentPass = hasFinal ? .final : .live
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, text FROM segment
                    WHERE meeting_id = ? AND pass = ? AND is_volatile = 0 AND is_echo_duplicate = 0
                    ORDER BY t_start_ms, id
                    """,
                arguments: [meetingID, pass.rawValue])
            for row in rows {
                let id: Int64 = row["id"]
                try add(row["text"], .segment, String(id))
            }
            if let raw = try RawNote.fetchOne(db, key: meetingID) {
                try add(raw.markdown, .raw, meetingID)
            }
            if let enhanced = try EnhancedNote.filter(Column("meeting_id") == meetingID)
                .order(Column("version").desc).fetchOne(db), let id = enhanced.id
            {
                try add(enhanced.markdown, .enhanced, String(id))
            }
            try add(meeting.title, .title, meetingID)
            for participant in try Participant.filter(Column("meeting_id") == meetingID).fetchAll(db) {
                if let id = participant.id { try add(participant.displayName, .person, String(id)) }
            }
        }
    }

    /// Full-text search, best match first. The query is sanitised (each token becomes a quoted prefix
    /// term); a blank or still-unparseable query yields no hits rather than an error.
    public func search(query: String, limit: Int = 50) async throws -> [SearchHit] {
        guard let match = Self.ftsQuery(query) else { return [] }
        do {
            return try await pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT meeting_id, kind, ref_id,
                               snippet(fts_content, 0, '<b>', '</b>', '…', 12) AS snippet,
                               bm25(fts_content) AS rank
                        FROM fts_content WHERE fts_content MATCH ?
                        ORDER BY rank LIMIT ?
                        """,
                    arguments: [match, limit]
                ).compactMap { row -> SearchHit? in
                    guard let kind = SearchKind(rawValue: row["kind"]) else { return nil }
                    return SearchHit(
                        meetingID: row["meeting_id"], kind: kind, refID: row["ref_id"],
                        snippet: row["snippet"], rank: row["rank"])
                }
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_ERROR {
            return []
        }
    }

    /// FTS5 MATCH expression: every whitespace-separated token as a quoted prefix term (`"pric"*`),
    /// embedded quotes doubled. Nil for a blank query.
    static func ftsQuery(_ query: String) -> String? {
        let terms = query.split(whereSeparator: \.isWhitespace).map { token in
            "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }
}
