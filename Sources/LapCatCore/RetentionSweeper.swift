import Foundation
import os

/// Deletes meeting audio once `meeting.audio_retained_until` has passed (PRD FR-11). The app calls
/// `sweep` on launch and every 6 h; `deleteAudioNow` backs the per-meeting "Delete audio now" button.
public struct RetentionSweeper: Sendable {
    private let store: Store
    private let paths: Paths
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "RetentionSweeper")

    public init(store: Store, paths: Paths = .standard) {
        self.store = store
        self.paths = paths
    }

    /// Deletes the audio of every meeting past retention: its files, its `audio/<id>/` directory and
    /// its `audio_file` rows, and clears `audio_retained_until`. Returns the swept meeting ids.
    @discardableResult
    public func sweep(now: Date = Date()) async throws -> [String] {
        let ids = try await store.meetingIDsPastAudioRetention(now: now)
        for id in ids { try await deleteAudioNow(meetingID: id) }
        if !ids.isEmpty { Self.logger.info("Deleted audio of \(ids.count) meeting(s) past retention") }
        return ids
    }

    /// Deletes one meeting's audio regardless of its retention date.
    public func deleteAudioNow(meetingID: String) async throws {
        let fm = FileManager.default
        for file in try await store.audioFiles(meetingID: meetingID) where fm.fileExists(atPath: file.path) {
            try fm.removeItem(atPath: file.path)
        }
        let dir = paths.audio(meetingID: meetingID)
        // Never resolve to the audio root or outside it (empty or path-like ids).
        let isOwnDirectory = !meetingID.isEmpty && !meetingID.contains("/") && meetingID != "." && meetingID != ".."
        if isOwnDirectory, fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try await store.deleteAudioFiles(meetingID: meetingID)
    }
}
