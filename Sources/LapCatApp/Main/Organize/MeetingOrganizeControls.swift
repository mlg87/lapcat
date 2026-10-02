import LapCatCore
import SwiftUI

/// Star toggle for a meeting (list rows and the meeting header).
struct StarButton: View {
    let meeting: Meeting
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            let store = appState.store
            let id = meeting.id
            let starred = !meeting.starred
            Task { try? await store.setStarred(meetingID: id, starred: starred) }
        } label: {
            Image(systemName: meeting.starred ? "star.fill" : "star")
                .foregroundStyle(meeting.starred ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(meeting.starred ? "Unstar" : "Star")
        .accessibilityLabel(meeting.starred ? "Unstar" : "Star")
    }
}

/// The meeting's tags as chips; "Edit tags" switches to a comma-separated text field that
/// replaces the tags on Return or when it loses focus.
struct TagEditor: View {
    let meetingID: String
    @Environment(AppState.self) private var appState
    @State private var tags: [String] = []
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag").foregroundStyle(.secondary).accessibilityHidden(true)
            if editing {
                TextField("Tags", text: $text, prompt: Text("Comma-separated tags"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                    .onExitCommand { editing = false }
            } else {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .accessibilityLabel("Tag \(tag)")
                }
                Button(tags.isEmpty ? "Add tags" : "Edit tags") {
                    text = TagList.format(tags)
                    editing = true
                    focused = true
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Edit tags (comma-separated)")
            }
            Spacer(minLength: 0)
        }
        .task(id: meetingID) {
            for await names in appState.store.observeTagNames(meetingID: meetingID) { tags = names }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let names = TagList.parse(text)
        guard names != tags else { return }
        let store = appState.store
        let id = meetingID
        Task { try? await store.setTags(meetingID: id, names) }
    }
}
