import Foundation
import GRDB

// MARK: - Templates sync and enhancement bookkeeping

extension Store {
    /// Upserts `builtins` and `custom` in one transaction and deletes every other template row of the
    /// same kind (a built-in no longer shipped, a custom file removed from the folder).
    public func replaceTemplates(builtins: [Template], custom: [Template]) async throws {
        try await pool.write { db in
            for template in builtins + custom { try template.insert(db, onConflict: .replace) }
            for (kind, kept) in [(true, builtins), (false, custom)] {
                let ids = kept.map(\.id)
                try Template
                    .filter(Column("is_builtin") == kind && !ids.contains(Column("id")))
                    .deleteAll(db)
            }
        }
    }

    public func template(id: String) async throws -> Template? {
        try await pool.read { db in try Template.fetchOne(db, key: id) }
    }

    /// Records which template and `<provider>:<model>` produced the meeting's newest enhanced note.
    /// Touches only those columns so a concurrent processing-step update is not overwritten.
    public func recordEnhancement(meetingID: String, templateID: String, providerUsed: String, now: Date = Date()) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET template_id = ?, llm_provider_used = ?, updated_at = ? WHERE id = ?",
                arguments: [templateID, providerUsed, now.timeIntervalSince1970, meetingID])
        }
    }

    /// Sets the title only while it still equals `expected`, so a user rename made while the LLM
    /// was writing a title wins. Returns whether the title changed.
    @discardableResult
    public func replaceMeetingTitle(id: String, expected: String, with title: String, now: Date = Date()) async throws -> Bool {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET title = ?, updated_at = ? WHERE id = ? AND title = ?",
                arguments: [title, now.timeIntervalSince1970, id, expected])
            return db.changesCount > 0
        }
    }
}
