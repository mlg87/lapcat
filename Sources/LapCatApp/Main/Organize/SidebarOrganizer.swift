import LapCatCore
import Observation
import os

/// Sidebar organisation state shared by the filter button and the meeting list: the active
/// filters and the folder list, plus the folder edits and moves the sidebar performs.
@Observable @MainActor
final class SidebarOrganizer {
    var listFilter = MeetingListFilter()
    private(set) var folders: [Folder] = []
    /// Last failed edit, shown in the sidebar until dismissed.
    var lastError: String?

    private static let logger = Logger(subsystem: "com.lapcat.app", category: "SidebarOrganizer")

    /// Keeps `folders` current; run from a view `.task`.
    func observeFolders(store: Store) async {
        for await folders in store.observeFolders() {
            self.folders = folders
            if let selected = listFilter.folderID, !folders.contains(where: { $0.id == selected }) {
                listFilter.folderID = nil
            }
        }
    }

    func folderName(id: String?) -> String? {
        id.flatMap { id in folders.first { $0.id == id }?.name }
    }

    func createFolder(named name: String, store: Store) {
        guard let name = Self.validName(name) else { return }
        perform("create folder") { _ = try await store.createFolder(name: name) }
    }

    func renameFolder(_ folder: Folder, to name: String, store: Store) {
        guard let name = Self.validName(name), name != folder.name else { return }
        perform("rename folder") { try await store.renameFolder(id: folder.id, to: name) }
    }

    /// Meetings in the folder stay, unfiled.
    func deleteFolder(_ folder: Folder, store: Store) {
        if listFilter.folderID == folder.id { listFilter.folderID = nil }
        perform("delete folder") { try await store.deleteFolder(id: folder.id) }
    }

    func move(meetingIDs: [String], toFolder folderID: String?, store: Store) {
        perform("move meeting") {
            for id in meetingIDs { try await store.setFolder(meetingID: id, folderID: folderID) }
        }
    }

    private static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func perform(_ action: String, _ body: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await body()
            } catch {
                Self.logger.error("\(action, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                lastError = "Could not \(action): \(error.localizedDescription)"
            }
        }
    }
}
