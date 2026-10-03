import LapCatCore
import SwiftUI

/// The main window: meeting list on the left, the selected meeting on the right.
///
/// The window is an AppKit-hosted `NSWindow` (see `WindowPresenter`) without an `NSToolbar`, so
/// search and actions live in the views themselves rather than in `.toolbar`/`.searchable`.
struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var organizer = SidebarOrganizer()

    var body: some View {
        @Bindable var navigation = appState.navigation
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarHeader
                if let query = searchQuery {
                    SearchResultsView(query: query)
                } else {
                    MeetingListView(filter: filter, selection: $navigation.selectedMeetingID)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
        } detail: {
            if let id = navigation.selectedMeetingID {
                MeetingView(meetingID: id).id(id)
            } else {
                ContentUnavailableView(
                    "No meeting selected", systemImage: "cat", description: Text("Pick a meeting, or start a new note.")
                )
            }
        }
        .environment(navigation)
        .environment(organizer)
        .task { await organizer.observeFolders(store: appState.store) }
        .frame(
            minWidth: 820, idealWidth: 1000, maxWidth: .infinity, minHeight: 520, idealHeight: 680, maxHeight: .infinity
        )
        .onChange(of: appState.session.meetingID, initial: true) { _, id in
            // A recording that starts shows itself.
            if let id { navigation.selectedMeetingID = id }
        }
    }

    /// The sidebar shows search results instead of the meeting list from two characters on.
    private var searchQuery: String? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.count >= 2 ? query : nil
    }

    private var filter: MeetingFilter {
        organizer.listFilter.meetingFilter(search: searchText)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
            SidebarFilterButton()
            Button {
                appState.startNewNote()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .labelStyle(.iconOnly)
            .help("New Note")
            .disabled(appState.session.state != .idle)
        }
        .padding(8)
    }
}
