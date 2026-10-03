import Foundation
import os

/// The `auto_export` post-meeting step (PRD FR-10.3): writes `MarkdownExporter.bundle` into the
/// user's export folder as `YYYY-MM-DD <Title>.md` and records the path in `meeting.export_path`.
public enum AutoExporter {
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "AutoExporter")

    /// Returns the written file, or nil when `folder` does not exist (logged; not an error, so the
    /// pipeline continues). Re-exporting a meeting overwrites its previous file; when the title changed
    /// the old file in the same folder is removed. A name taken by another file gets a ` 2`, ` 3`, … suffix.
    @discardableResult
    public static func export(
        meetingID: String, folder: URL, store: Store, timeZone: TimeZone = .current
    ) async throws -> URL? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            logger.warning("Auto-export folder missing: \(folder.path, privacy: .public)")
            return nil
        }
        let export = try await MeetingExport.load(meetingID: meetingID, store: store)
        let previous = export.meeting.exportPath.map { URL(fileURLWithPath: $0).standardizedFileURL }

        let base = MarkdownExporter.fileName(for: export.meeting, fileExtension: "md", timeZone: timeZone)
        let stem = String(base.dropLast(3))
        var target = folder.appendingPathComponent(base).standardizedFileURL
        var suffix = 2
        while fm.fileExists(atPath: target.path), target != previous {
            target = folder.appendingPathComponent("\(stem) \(suffix).md").standardizedFileURL
            suffix += 1
        }

        try Data(MarkdownExporter.bundle(export, timeZone: timeZone).utf8).write(to: target, options: .atomic)
        if let previous, previous != target,
            previous.deletingLastPathComponent() == target.deletingLastPathComponent(),
            fm.fileExists(atPath: previous.path)
        {
            try? fm.removeItem(at: previous)
        }
        try await store.setExportPath(meetingID: meetingID, path: target.path)
        return target
    }
}
