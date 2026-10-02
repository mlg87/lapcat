import LapCatCore
import SwiftUI

/// Sidebar full-text search results (plan §10.1): best match first, each with the meeting title, a kind
/// badge, the highlighted snippet and the date. Selecting a hit opens its meeting on the matching tab.
struct SearchResultsView: View {
    let query: String
    @Environment(AppState.self) private var appState
    @State private var hits: [SearchHit] = []
    @State private var meetings: [String: Meeting] = [:]
    @State private var selection: SearchHit.ID?
    @State private var loaded = false

    var body: some View {
        List(selection: $selection) {
            ForEach(hits) { hit in
                SearchHitRow(hit: hit, meeting: meetings[hit.meetingID]).tag(hit.id)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if loaded, hits.isEmpty {
                Text("No results").foregroundStyle(.secondary)
            }
        }
        .onChange(of: selection) { _, id in
            guard let id, let hit = hits.first(where: { $0.id == id }) else { return }
            appState.navigation.open(hit)
        }
        .task(id: query) {
            // Debounce typing; a newer query cancels this task.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let store = appState.store
            let found = (try? await store.search(query: query, limit: 50)) ?? []
            var byID: [String: Meeting] = [:]
            for id in Set(found.map(\.meetingID)) {
                if let meeting = try? await store.meeting(id: id) { byID[id] = meeting }
            }
            guard !Task.isCancelled else { return }
            meetings = byID
            hits = found.filter { byID[$0.meetingID] != nil }
            selection = nil
            loaded = true
        }
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit
    let meeting: Meeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(meeting?.title ?? "Untitled").lineLimit(1)
                Spacer(minLength: 4)
                Text(hit.kind.badgeLabel)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
            Text(SearchSnippet.attributed(hit.snippet))
                .font(.callout)
                .lineLimit(3)
            if let meeting {
                Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
