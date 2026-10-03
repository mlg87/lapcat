import AppKit
import LapCatCore
import SwiftUI

/// One meeting: header (title, status, provider, recording controls, Enhance) and either the
/// recording layout (notes + live transcript) or the Notes / Enhanced / Transcript tabs.
struct MeetingView: View {
    let meetingID: String
    @Environment(AppState.self) private var appState
    @Environment(MeetingNavigation.self) private var navigation
    @State private var meeting: Meeting?
    @State private var segments: [Segment] = []
    @State private var participants: [Participant] = []
    @State private var showLiveTranscript = true
    @State private var enhancing = false
    @State private var enhanceError: String?

    var body: some View {
        Group {
            if let meeting {
                VStack(spacing: 0) {
                    MeetingHeader(
                        meeting: meeting, enhancing: enhancing, showLiveTranscript: $showLiveTranscript,
                        enhance: enhance)
                    banners(meeting)
                    Divider()
                    content(meeting)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            for await meeting in appState.store.observeMeeting(id: meetingID) { self.meeting = meeting }
        }
        .task {
            for await segments in appState.store.observeSegments(meetingID: meetingID) { self.segments = segments }
        }
        .task {
            for await participants in appState.store.observeParticipants(meetingID: meetingID) {
                self.participants = participants
            }
        }
    }

    @ViewBuilder
    private func banners(_ meeting: Meeting) -> some View {
        if meeting.status == .recording, appState.settings.consentReminderEnabled, !meeting.consentConfirmed {
            Banner(systemImage: "person.2.wave.2", tint: .blue) {
                Text("Remember to let participants know you're taking AI notes.")
            } actions: {
                Button("Copy disclosure") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(appState.settings.consentCannedMessage, forType: .string)
                    Task { try? await appState.store.setConsentConfirmed(meetingID: meeting.id) }
                }
            }
        }
        if meeting.status == .error {
            Banner(systemImage: "exclamationmark.triangle", tint: .orange) {
                Text("Processing failed: \(meeting.errorMessage ?? "unknown error")").lineLimit(3)
            } actions: {
                Button("Retry processing") {
                    let pipeline = appState.pipeline
                    Task { await pipeline.enqueue(meeting.id) }
                }
            }
        }
        if let enhanceError {
            Banner(systemImage: "exclamationmark.triangle", tint: .orange) {
                Text("Enhance failed: \(enhanceError)").lineLimit(3)
            } actions: {
                Button("Dismiss") { self.enhanceError = nil }
            }
        }
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        if meeting.status == .recording {
            HSplitView {
                NotesEditor(meetingID: meeting.id)
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                if showLiveTranscript {
                    LiveTranscriptPanel(segments: segments, participants: participants)
                        .frame(minWidth: 260, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            @Bindable var navigation = navigation
            TabView(selection: $navigation.tab) {
                NotesEditor(meetingID: meeting.id)
                    .tabItem { Text("Notes") }
                    .tag(MeetingNavigation.Tab.notes)
                EnhancedNoteView(meetingID: meeting.id, enhancing: enhancing, enhance: enhance)
                    .tabItem { Text("Enhanced") }
                    .tag(MeetingNavigation.Tab.enhanced)
                TranscriptViewer(meetingID: meeting.id, segments: segments, participants: participants)
                    .tabItem { Text("Transcript") }
                    .tag(MeetingNavigation.Tab.transcript)
                ChatView(
                    scope: .meeting, scopeRef: meeting.id, placeholder: "Ask about this meeting — type / for recipes"
                )
                .tabItem { Text("Chat") }
                .tag(MeetingNavigation.Tab.chat)
            }
            .padding(8)
        }
    }

    private func enhance(_ templateID: String, _ providerID: String?) {
        guard !enhancing else { return }
        enhancing = true
        enhanceError = nil
        Task {
            defer { enhancing = false }
            do {
                try await appState.enhance(meetingID: meetingID, templateID: templateID, providerID: providerID)
                if meeting?.status != .recording { navigation.tab = .enhanced }
            } catch {
                enhanceError = error.localizedDescription
            }
        }
    }
}

/// Star, title field, status and provider badges, Pause/End while recording, Enhance, Export and
/// More (Delete Meeting…) menus; tags below.
private struct MeetingHeader: View {
    let meeting: Meeting
    let enhancing: Bool
    @Binding var showLiveTranscript: Bool
    let enhance: (String, String?) -> Void
    @Environment(AppState.self) private var appState
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var pendingDelete: Meeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            controls
            TagEditor(meetingID: meeting.id)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .deleteMeetingConfirmation($pendingDelete)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            StarButton(meeting: meeting)
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                .onChange(of: meeting.title, initial: true) { _, new in if !titleFocused { title = new } }
            Spacer(minLength: 8)
            MeetingStatusBadge(meeting: meeting)
            if let provider = meeting.llmProviderUsed {
                Badge(text: ProviderLabel.displayName(provider), systemImage: "sparkles", tint: .purple)
                    .help(provider)
            }
            if isActiveRecording {
                Button(appState.session.isPaused ? "Resume" : "Pause") { appState.togglePause() }
                Button("End") { appState.endSession() }
            }
            if enhancing {
                ProgressView().controlSize(.small)
                Text("Enhancing…").foregroundStyle(.secondary)
            } else {
                EnhanceMenu(title: "Enhance", enhance: enhance)
            }
            ExportMenu(meetingID: meeting.id)
            if meeting.status == .recording {
                Toggle(isOn: $showLiveTranscript) {
                    Label("Live transcript", systemImage: "text.bubble")
                }
                .toggleStyle(.button)
                .help("Show or hide the live transcript")
            }
            Menu {
                Button("Delete Meeting…", role: .destructive) { pendingDelete = meeting }
                    .disabled(!meeting.isDeletable || enhancing)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    private var isActiveRecording: Bool { appState.session.meetingID == meeting.id && meeting.status == .recording }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            title = meeting.title
            return
        }
        guard trimmed != meeting.title else { return }
        let store = appState.store
        let id = meeting.id
        Task {
            try? await store.renameMeeting(id: id, to: trimmed)
            try? await store.reindexFTS(meetingID: id)
        }
    }
}

/// `Enhance ▾`: Auto + every template, plus a per-provider submenu with the same choices.
struct EnhanceMenu: View {
    let title: String
    let enhance: (String, String?) -> Void
    @Environment(AppState.self) private var appState
    @State private var templates: [Template] = []

    var body: some View {
        Menu(title) {
            choices(providerID: nil)
            Divider()
            Menu("With provider") {
                ForEach(appState.settings.llmProviderOrder, id: \.self) { provider in
                    Menu(ProviderLabel.displayName(provider)) { choices(providerID: provider) }
                }
            }
        }
        .fixedSize()
        .task {
            templates = (try? await appState.store.templates()) ?? []
        }
    }

    @ViewBuilder
    private func choices(providerID: String?) -> some View {
        Button("Auto") { enhance(TemplateLibrary.autoID, providerID) }
        ForEach(templates) { template in
            Button(template.name) { enhance(template.id, providerID) }
        }
    }
}

/// `Recording 12:34` / `Paused 12:34` / `Processing: <step>` / `Ready` / `Error`.
struct MeetingStatusBadge: View {
    let meeting: Meeting
    @Environment(AppState.self) private var appState

    var body: some View {
        switch meeting.status {
        case .recording:
            let session = appState.session
            if session.meetingID == meeting.id {
                let time = MenuBarLabel.format(session.elapsed(at: session.clock))
                Badge(
                    text: session.isPaused ? "Paused \(time)" : "Recording \(time)", systemImage: "record.circle",
                    tint: .red)
            } else {
                Badge(text: "Recording", systemImage: "record.circle", tint: .red)
            }
        case .processing:
            let step =
                meeting.processingStep.map { PostMeetingPipeline.Step(rawValue: $0)?.displayName ?? $0 } ?? "Queued"
            Badge(text: "Processing: \(step)", systemImage: "gearshape.2", tint: .blue)
        case .ready:
            Badge(text: "Ready", systemImage: "checkmark.circle", tint: .green)
        case .error:
            Badge(text: "Error", systemImage: "exclamationmark.triangle", tint: .orange)
        }
    }
}

struct Badge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// A full-width notice with trailing actions.
struct Banner<Message: View, Actions: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder let message: Message
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            message
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1))
    }
}
