import LapCatCore
import SwiftUI

/// `Export ▾` in the meeting header: copy notes (Markdown / plain text), export the meeting
/// document, export the transcript.
struct ExportMenu: View {
    let meetingID: String
    @Environment(AppState.self) private var appState
    @State private var error: String?

    var body: some View {
        Menu("Export") {
            Button("Copy Notes as Markdown") { run { await MeetingExportActions.copyNotes(meetingID: meetingID, as: .markdown, store: $0) } }
            Button("Copy as Plain Text") { run { await MeetingExportActions.copyNotes(meetingID: meetingID, as: .plainText, store: $0) } }
            Divider()
            Button("Export Meeting (.md)…") { run { await MeetingExportActions.exportMeeting(meetingID: meetingID, store: $0) } }
            Button("Export Transcript…") { run { await MeetingExportActions.exportTranscript(meetingID: meetingID, store: $0) } }
        }
        .fixedSize()
        .exportErrorAlert($error)
    }

    private func run(_ action: @escaping @MainActor (Store) async -> String?) {
        let store = appState.store
        Task { error = await action(store) }
    }
}

extension View {
    /// Shows an export failure message until dismissed.
    func exportErrorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Export failed",
            isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
