import Foundation
import GRDB

/// The app database: a WAL `DatabasePool` with foreign keys on, migrated to the latest schema on open.
public final class Store: Sendable {
    let pool: DatabasePool

    /// Read access for `ValueObservation` in the UI.
    public var reader: any DatabaseReader { pool }

    public init(databaseURL: URL = Paths.standard.database) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        pool = try DatabasePool(path: databaseURL.path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: v1Schema)
        }
        return migrator
    }

    static let v1Schema = """
        CREATE TABLE folder(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          sort_order INTEGER NOT NULL DEFAULT 0);

        CREATE TABLE meeting(
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          started_at REAL NOT NULL,
          ended_at REAL,
          status TEXT NOT NULL CHECK(status IN ('recording','processing','ready','error')),
          source_app TEXT NOT NULL DEFAULT 'other',
          source_bundle_id TEXT,
          source_pid INTEGER,
          started_by TEXT NOT NULL CHECK(started_by IN ('manual','prompt')),
          calendar_event_id TEXT,
          folder_id TEXT REFERENCES folder(id) ON DELETE SET NULL,
          starred INTEGER NOT NULL DEFAULT 0,
          template_id TEXT,
          llm_provider_used TEXT,
          audio_retained_until REAL,
          processing_step TEXT,
          error_message TEXT,
          consent_confirmed INTEGER NOT NULL DEFAULT 0,
          export_path TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL);

        CREATE TABLE calendar_snapshot(
          meeting_id TEXT PRIMARY KEY REFERENCES meeting ON DELETE CASCADE,
          event_title TEXT,
          organizer TEXT,
          attendees_json TEXT NOT NULL DEFAULT '[]',
          conference_url TEXT,
          scheduled_start REAL,
          scheduled_end REAL);

        CREATE TABLE voiceprint(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          participant_name TEXT NOT NULL,
          embedding BLOB NOT NULL,
          created_at REAL NOT NULL);

        CREATE TABLE participant(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          meeting_id TEXT NOT NULL REFERENCES meeting ON DELETE CASCADE,
          display_name TEXT NOT NULL,
          email TEXT,
          source TEXT NOT NULL CHECK(source IN ('calendar','zoom_ax','meet_ax','manual','llm_suggested','cluster')),
          is_me INTEGER NOT NULL DEFAULT 0,
          cluster_label TEXT,
          voiceprint_id INTEGER,
          UNIQUE(meeting_id, display_name));

        CREATE TABLE speaker_event(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          meeting_id TEXT NOT NULL REFERENCES meeting ON DELETE CASCADE,
          t_start_ms INTEGER NOT NULL,
          t_end_ms INTEGER,
          display_name TEXT NOT NULL,
          source TEXT NOT NULL CHECK(source IN ('zoom_ax','meet_ax')));
        CREATE INDEX speaker_event_meeting_start ON speaker_event(meeting_id, t_start_ms);

        CREATE TABLE segment(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          meeting_id TEXT NOT NULL REFERENCES meeting ON DELETE CASCADE,
          channel TEXT NOT NULL CHECK(channel IN ('mic','system')),
          t_start_ms INTEGER NOT NULL,
          t_end_ms INTEGER NOT NULL,
          text TEXT NOT NULL,
          text_original TEXT,
          participant_id INTEGER REFERENCES participant(id) ON DELETE SET NULL,
          cluster_label TEXT,
          confidence REAL,
          pass TEXT NOT NULL CHECK(pass IN ('live','final')),
          is_volatile INTEGER NOT NULL DEFAULT 0,
          is_echo_duplicate INTEGER NOT NULL DEFAULT 0,
          edited_at REAL);
        CREATE INDEX segment_meeting_pass_start ON segment(meeting_id, pass, t_start_ms);

        CREATE TABLE raw_note(
          meeting_id TEXT PRIMARY KEY REFERENCES meeting ON DELETE CASCADE,
          markdown TEXT NOT NULL DEFAULT '',
          updated_at REAL NOT NULL);

        CREATE TABLE enhanced_note(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          meeting_id TEXT NOT NULL REFERENCES meeting ON DELETE CASCADE,
          version INTEGER NOT NULL,
          template_id TEXT NOT NULL,
          provider TEXT NOT NULL,
          model TEXT NOT NULL,
          markdown TEXT NOT NULL,
          citations_json TEXT NOT NULL DEFAULT '[]',
          based_on_pass TEXT NOT NULL CHECK(based_on_pass IN ('live','final')),
          created_at REAL NOT NULL,
          UNIQUE(meeting_id, version));

        CREATE TABLE template(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '',
          body_markdown TEXT NOT NULL,
          is_builtin INTEGER NOT NULL,
          file_path TEXT,
          updated_at REAL NOT NULL);

        CREATE TABLE recipe(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          slash_command TEXT NOT NULL UNIQUE,
          prompt TEXT NOT NULL,
          is_builtin INTEGER NOT NULL);

        CREATE TABLE chat_thread(
          id TEXT PRIMARY KEY,
          scope TEXT NOT NULL CHECK(scope IN ('meeting','folder','global')),
          scope_ref TEXT,
          title TEXT,
          created_at REAL NOT NULL);

        CREATE TABLE chat_message(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          thread_id TEXT NOT NULL REFERENCES chat_thread ON DELETE CASCADE,
          role TEXT NOT NULL CHECK(role IN ('user','assistant')),
          content TEXT NOT NULL,
          citations_json TEXT NOT NULL DEFAULT '[]',
          provider TEXT,
          model TEXT,
          created_at REAL NOT NULL);

        CREATE TABLE tag(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE);

        CREATE TABLE meeting_tag(
          meeting_id TEXT REFERENCES meeting ON DELETE CASCADE,
          tag_id TEXT REFERENCES tag ON DELETE CASCADE,
          PRIMARY KEY(meeting_id, tag_id));

        CREATE TABLE audio_file(
          meeting_id TEXT REFERENCES meeting ON DELETE CASCADE,
          channel TEXT NOT NULL,
          path TEXT NOT NULL,
          codec TEXT NOT NULL DEFAULT 'aac-adts',
          duration_ms INTEGER,
          PRIMARY KEY(meeting_id, channel));

        CREATE VIRTUAL TABLE fts_content USING fts5(
          text, meeting_id UNINDEXED, kind UNINDEXED, ref_id UNINDEXED,
          tokenize='porter unicode61');
        """
}
