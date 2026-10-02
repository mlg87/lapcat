import LapCatCore
import SwiftUI

/// Meetings matching `filter`, newest first, in Today / Yesterday / This week / Earlier sections.
struct MeetingListView: View {
    let filter: MeetingFilter
    @Binding var selection: String?
    @Environment(AppState.self) private var appState
    @State private var meetings: [Meeting] = []
    @State private var loaded = false

    var body: some View {
        List(selection: $selection) {
            ForEach(MeetingListSection.group(meetings), id: \.0) { section, items in
                Section(section.rawValue) {
                    ForEach(items) { meeting in
                        MeetingRow(meeting: meeting).tag(meeting.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if loaded, meetings.isEmpty {
                Text(filter.search == nil ? "No meetings yet" : "No matching meetings")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: filter) {
            for await meetings in appState.store.observeMeetings(filter: filter) {
                self.meetings = meetings
                loaded = true
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                if meeting.status != .ready {
                    MeetingStatusText(meeting: meeting)
                }
                if meeting.starred {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Starred")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
