import LapCatCore
import SwiftUI

/// Folders, then the meetings matching `filter`, newest first, in Today / Yesterday / This week /
/// Earlier sections. Meeting rows star in place, drag onto a folder, or move via their context menu.
struct MeetingListView: View {
    let filter: MeetingFilter
    @Binding var selection: String?
    @Environment(AppState.self) private var appState
    @Environment(SidebarOrganizer.self) private var organizer
    @State private var meetings: [Meeting] = []
    @State private var loaded = false

    var body: some View {
        List(selection: $selection) {
            FolderSection()
            ForEach(MeetingListSection.group(meetings), id: \.0) { section, items in
                Section(section.rawValue) {
                    ForEach(items) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(meeting.id)
                            .draggable(meeting.id)
                            .contextMenu { moveMenu(meeting) }
                    }
                }
            }
            if loaded, meetings.isEmpty {
                Text(isFiltered ? "No matching meetings" : "No meetings yet")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .task(id: filter) {
            for await meetings in appState.store.observeMeetings(filter: filter) {
                self.meetings = meetings
                loaded = true
            }
        }
    }

    private var isFiltered: Bool { filter != MeetingFilter() }

    @ViewBuilder
    private func moveMenu(_ meeting: Meeting) -> some View {
        Menu("Move to Folder") {
            Button("None") { organizer.move(meetingIDs: [meeting.id], toFolder: nil, store: appState.store) }
                .disabled(meeting.folderID == nil)
            Divider()
            ForEach(organizer.folders) { folder in
                Button(folder.name) {
                    organizer.move(meetingIDs: [meeting.id], toFolder: folder.id, store: appState.store)
                }
                .disabled(meeting.folderID == folder.id)
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    @Environment(SidebarOrganizer.self) private var organizer

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    if meeting.status != .ready {
                        MeetingStatusText(meeting: meeting)
                    }
                    if organizer.listFilter.folderID == nil, let folder = organizer.folderName(id: meeting.folderID) {
                        Label(folder, systemImage: "folder").lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            StarButton(meeting: meeting)
        }
        .padding(.vertical, 2)
    }
}

/// Short status for list rows: `Recording`, `Processing`, `Error`.
private struct MeetingStatusText: View {
    let meeting: Meeting

    var body: some View {
        switch meeting.status {
        case .recording: Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
        case .processing: Label("Processing", systemImage: "gearshape.2")
        case .error: Label("Error", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .ready: EmptyView()
        }
    }
}
