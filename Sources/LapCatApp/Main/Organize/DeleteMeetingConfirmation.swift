import LapCatCore
import SwiftUI

/// The "Delete Meeting" confirmation shared by the meeting list and the meeting header. Setting the
/// binding to a meeting shows the dialog; confirming deletes the meeting through `SidebarOrganizer`.
private struct DeleteMeetingConfirmation: ViewModifier {
    @Binding var meeting: Meeting?
    @Environment(AppState.self) private var appState
    @Environment(MeetingNavigation.self) private var navigation
    @Environment(SidebarOrganizer.self) private var organizer

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete \u{201C}\(meeting?.title ?? "")\u{201D}?",
            isPresented: Binding(get: { meeting != nil }, set: { if !$0 { meeting = nil } }),
            presenting: meeting
        ) { meeting in
            Button("Delete Meeting", role: .destructive) {
                organizer.deleteMeeting(meeting, store: appState.store, navigation: navigation)
            }
        } message: { _ in
            Text(
                "LapCat deletes the notes, enhanced notes, transcript, chat and audio of this meeting. "
                    + "You cannot undo this. Files in your export folder stay.")
        }
    }
}

extension View {
    func deleteMeetingConfirmation(_ meeting: Binding<Meeting?>) -> some View {
        modifier(DeleteMeetingConfirmation(meeting: meeting))
    }
}
