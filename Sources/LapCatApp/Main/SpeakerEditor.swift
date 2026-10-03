import LapCatCore
import SwiftUI

/// Popover for a transcript paragraph's speaker: rename meeting-wide, merge into another
/// speaker, or reassign this paragraph. The search index is rebuilt after each change.
struct SpeakerEditor: View {
    let meetingID: String
    let paragraph: TranscriptParagraph
    let speaker: String
    let participants: [Participant]
    let dismiss: () -> Void
    @Environment(AppState.self) private var appState
    @State private var name = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var participant: Participant? {
        paragraph.participantID.flatMap { id in participants.first { $0.id == id } }
    }

    /// Every other speaker of the meeting.
    private var others: [Participant] {
        participants.filter { $0.id != paragraph.participantID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speaker: \(speaker)").font(.headline)
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                    .focused($nameFocused)
                    .onSubmit(rename)
                Button("Rename", action: rename)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(
                participant == nil
                    ? "Renames every unassigned \(paragraph.channel == .mic ? "Me" : "Them") paragraph in this meeting."
                    : "Renames \(speaker) everywhere in this meeting."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            if let participant, let id = participant.id {
                Menu("Merge into…") {
                    ForEach(others) { other in
                        Button(other.displayName) {
                            run { store in
                                guard let keep = other.id else { return }
                                try await store.mergeParticipants(keep: keep, remove: id)
                            }
                        }
                    }
                }
                .disabled(others.isEmpty)
            }
            Menu("Reassign paragraph to…") {
                ForEach(others) { other in
                    Button(other.displayName) { reassign(to: other.id) }
                }
                if paragraph.participantID != nil {
                    Divider()
                    Button(paragraph.channel == .mic ? "Me (unassigned)" : "Them (unassigned)") { reassign(to: nil) }
                }
            }
            .disabled(others.isEmpty && paragraph.participantID == nil)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            name = speaker
            nameFocused = true
        }
    }

    private func rename() {
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        let meetingID = meetingID
        let channel = paragraph.channel
        let participantID = paragraph.participantID
        run { store in
            if let participantID {
                try await store.renameParticipant(id: participantID, to: newName)
            } else {
                // "Me"/"Them" without a participant: name every unassigned segment of the channel.
                let target = try await store.upsertParticipant(
                    meetingID: meetingID, name: newName, source: .manual, isMe: channel == .mic)
                guard let targetID = target.id else { return }
                for segment in try await store.segments(meetingID: meetingID)
                where segment.channel == channel && segment.participantID == nil {
                    if let id = segment.id { try await store.assignSegment(id: id, participantID: targetID) }
                }
            }
        }
    }

    private func reassign(to participantID: Int64?) {
        let ids = paragraph.segments.compactMap(\.id)
        run { store in
            for id in ids { try await store.assignSegment(id: id, participantID: participantID) }
        }
    }

    private func run(_ change: @escaping @Sendable (Store) async throws -> Void) {
        let store = appState.store
        let meetingID = meetingID
        Task {
            do {
                try await change(store)
                try await store.reindexFTS(meetingID: meetingID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// "Speaker 1 might be Priya Shah — Confirm / Dismiss" for each pending suggestion.
struct SpeakerSuggestionBanners: View {
    let meetingID: String
    let suggestions: [SpeakerSuggestion]
    @Environment(AppState.self) private var appState

    var body: some View {
        ForEach(suggestions) { suggestion in
            Banner(systemImage: "person.crop.circle.badge.questionmark", tint: .purple) {
                Text("\(suggestion.clusterLabel) might be \(suggestion.suggested.displayName)")
            } actions: {
                Button("Confirm") {
                    guard let keep = suggestion.suggested.id, let cluster = suggestion.cluster.id else { return }
                    update { try await $0.confirmSpeakerSuggestion(suggestedID: keep, clusterID: cluster) }
                }
                Button("Dismiss") {
                    guard let id = suggestion.suggested.id else { return }
                    update { try await $0.dismissSpeakerSuggestion(suggestedID: id) }
                }
            }
        }
    }

    private func update(_ change: @escaping @Sendable (Store) async throws -> Void) {
        let store = appState.store
        let meetingID = meetingID
        Task {
            try? await change(store)
            try? await store.reindexFTS(meetingID: meetingID)
        }
    }
}
