import Foundation
import GRDB

// Queries behind chat context building, export and retention.

extension Store {
    /// Full-text search that matches documents containing *any* keyword of `query` (best bm25 first),
    /// for natural-language chat questions where `search(query:)`'s all-terms match finds nothing.
    /// Common English stop words are dropped; kinds, folder and meeting date range filter in SQL so
    /// `limit` applies after filtering. A blank or unparseable query yields no hits.
    public func search(
        anyOf query: String,
        kinds: Set<SearchKind>,
        folderID: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        limit: Int = 40
    ) async throws -> [SearchHit] {
        guard let match = Self.ftsAnyQuery(query), !kinds.isEmpty else { return [] }
        var sql = """
            SELECT fts_content.meeting_id AS meeting_id, kind, ref_id,
                   snippet(fts_content, 0, '<b>', '</b>', '…', 12) AS snippet,
                   bm25(fts_content) AS rank
            FROM fts_content JOIN meeting ON meeting.id = fts_content.meeting_id
            WHERE fts_content MATCH ?
            """
        var args: StatementArguments = [match]
        let kindList = kinds.map(\.rawValue).sorted()
        sql += " AND kind IN (\(databaseQuestionMarks(count: kindList.count)))"
        args += StatementArguments(kindList)
        if let folderID {
            sql += " AND meeting.folder_id = ?"
            args += [folderID]
        }
        if let range = dateRange {
            sql += " AND meeting.started_at >= ? AND meeting.started_at <= ?"
            args += [range.lowerBound.timeIntervalSince1970, range.upperBound.timeIntervalSince1970]
        }
        sql += " ORDER BY rank LIMIT ?"
        args += [limit]
        let (finalSQL, finalArgs) = (sql, args)
        do {
            return try await pool.read { db in
                try Row.fetchAll(db, sql: finalSQL, arguments: finalArgs).compactMap { row -> SearchHit? in
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

    /// FTS5 OR-expression of the query's keywords as quoted prefix terms. Nil when no keyword remains.
    static func ftsAnyQuery(_ query: String) -> String? {
        var seen = Set<String>()
        let terms = query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) && seen.insert($0).inserted }
            .map { "\"\($0)\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    private static let stopWords: Set<String> = [
        "a", "about", "after", "all", "am", "an", "and", "any", "are", "as", "at", "be", "been", "before", "but",
        "by", "can", "could", "did", "do", "does", "for", "from", "had", "has", "have", "he", "her", "him", "his",
        "how", "if", "in", "into", "is", "it", "its", "me", "my", "of", "on", "or", "our", "she", "so", "that",
        "the", "their", "them", "then", "there", "they", "this", "to", "us", "was", "we", "were", "what", "when",
        "where", "which", "who", "whom", "why", "will", "with", "would", "you", "your", "tell", "said", "say",
    ]

    /// Segments with the given ids (any meeting), ordered by meeting and start time.
    public func segments(ids: [Int64]) async throws -> [Segment] {
        guard !ids.isEmpty else { return [] }
        return try await pool.read { db in
            try Segment.filter(ids.contains(Column("id")))
                .order(Column("meeting_id"), Column("t_start_ms"), Column("id"))
                .fetchAll(db)
        }
    }

    public func setExportPath(meetingID: String, path: String?, now: Date = Date()) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET export_path = ?, updated_at = ? WHERE id = ?",
                arguments: [path, now.timeIntervalSince1970, meetingID])
        }
    }

    /// Ids of meetings whose `audio_retained_until` is at or before `now`.
    public func meetingIDsPastAudioRetention(now: Date = Date()) async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(
                db,
                sql:
                    "SELECT id FROM meeting WHERE audio_retained_until IS NOT NULL AND audio_retained_until <= ? ORDER BY id",
                arguments: [now.timeIntervalSince1970])
        }
    }
}
