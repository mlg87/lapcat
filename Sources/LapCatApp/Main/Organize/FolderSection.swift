import LapCatCore
import SwiftUI

/// The sidebar's Folders section: "All meetings" plus every folder. Clicking a row filters the
/// list to it; dropping meeting rows onto a folder files them there ("All meetings" unfiles them).
/// Folders are created from the section's + button and renamed/deleted from their context menu.
struct FolderSection: View {
    @Environment(AppState.self) private var appState
    @Environment(SidebarOrganizer.self) private var organizer
    @State private var naming: FolderNaming?
    @State private var nameText = ""
    @State private var pendingDelete: Folder?

    var body: some View {
        Section {
            FolderRow(title: "All meetings", systemImage: "tray.full", isSelected: organizer.listFilter.folderID == nil)
            {
                organizer.listFilter.folderID = nil
            } drop: { ids in
                organizer.move(meetingIDs: ids, toFolder: nil, store: appState.store)
            }
            ForEach(organizer.folders) { folder in
                FolderRow(
                    title: folder.name, systemImage: "folder", isSelected: organizer.listFilter.folderID == folder.id
                ) {
                    organizer.listFilter.folderID = folder.id
                } drop: { ids in
                    organizer.move(meetingIDs: ids, toFolder: folder.id, store: appState.store)
                }
                .contextMenu {
                    Button("Rename Folder…") { beginNaming(.rename(folder)) }
                    Button("Delete Folder…", role: .destructive) { pendingDelete = folder }
                }
            }
            Button {
                beginNaming(.create)
            } label: {
                Label("New Folder…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .help("New Folder")
            if let error = organizer.lastError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { organizer.lastError = nil }.buttonStyle(.link).font(.caption)
                }
            }
        } header: {
            Text("Folders")
                // Attached to the header, which exists once (modifiers on a Section apply to each row).
                .alert(
                    naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
                ) {
                    TextField("Folder name", text: $nameText)
                    Button(naming?.confirmTitle ?? "OK") { commitNaming() }
                    Button("Cancel", role: .cancel) { naming = nil }
                }
                .confirmationDialog(
                    "Delete folder \u{201C}\(pendingDelete?.name ?? "")\u{201D}?",
                    isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
                ) {
                    Button("Delete Folder", role: .destructive) {
                        if let folder = pendingDelete { organizer.deleteFolder(folder, store: appState.store) }
                        pendingDelete = nil
                    }
                } message: {
                    Text("Its meetings are kept and become unfiled.")
                }
        }
    }

    private func beginNaming(_ mode: FolderNaming) {
        if case .rename(let folder) = mode { nameText = folder.name } else { nameText = "" }
        naming = mode
    }

    private func commitNaming() {
        switch naming {
        case .create: organizer.createFolder(named: nameText, store: appState.store)
        case .rename(let folder): organizer.renameFolder(folder, to: nameText, store: appState.store)
        case nil: break
        }
        naming = nil
    }
}

private enum FolderNaming {
    case create
    case rename(Folder)

    var title: String {
        switch self {
        case .create: "New Folder"
        case .rename: "Rename Folder"
        }
    }

    var confirmTitle: String {
        switch self {
        case .create: "Create"
        case .rename: "Rename"
        }
    }
}

private struct FolderRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let select: () -> Void
    let drop: ([String]) -> Void
    @State private var isTargeted = false

    var body: some View {
        Button(action: select) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(isSelected ? .semibold : .regular)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isTargeted ? Color.accentColor.opacity(0.35) : isSelected ? Color.secondary.opacity(0.18) : .clear)
        )
        .help("Show \(title); drop meetings here to move them")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .dropDestination(for: String.self) { ids, _ in
            guard !ids.isEmpty else { return false }
            drop(ids)
            return true
        } isTargeted: {
            isTargeted = $0
        }
    }
}
