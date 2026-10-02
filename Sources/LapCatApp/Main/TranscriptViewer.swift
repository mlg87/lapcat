import AppKit
import LapCatCore
import SwiftUI

/// The Transcript tab: timestamped speaker paragraphs with find (⌘F, ⌘G / ⇧⌘G), jump to time,
/// inline edits (double-click), speaker editing, playback from a paragraph and copy.
struct TranscriptViewer: View {
    let meetingID: String
    let segments: [Segment]
    let participants: [Participant]
    @Environment(AppState.self) private var appState
    @Environment(MeetingNavigation.self) private var navigation
    @State private var showEcho = false
    @State private var findText = ""
    @State private var currentMatch: Int?
    @State private var jumpText = ""
    @State private var jumpError = false
    @State private var selection = Set<Int64>()
    @State private var editingSegmentID: Int64?
    @State private var editText = ""
    @State private var speakerPopover: Int64?
    @State private var highlightedSegmentID: Int64?
    @State private var jumpTarget: Int64?
    @State private var handledRequest: UUID?
    @State private var player = TranscriptPlayer()
    @State private var confirmDeleteAudio = false
    @State private var deletingAudio = false
    @State private var exportError: String?
    @FocusState private var findFocused: Bool
    @FocusState private var editFocused: Bool

    private var paragraphs: [TranscriptParagraph] { TranscriptGrouping.paragraphs(segments, showEcho: showEcho) }
    private var matches: [TranscriptFindMatch] { TranscriptFind.matches(findText, in: paragraphs.flatMap(\.segments)) }

    var body: some View {
        let paragraphs = paragraphs
        let matches = matches
        VStack(spacing: 0) {
            SpeakerSuggestionBanners(
                meetingID: meetingID, suggestions: SpeakerSuggestion.pending(participants: participants, segments: segments))
            controls(paragraphs: paragraphs, matches: matches)
            Divider()
            ScrollViewReader { proxy in
                transcript(paragraphs: paragraphs, matches: matches)
                    .onChange(of: currentMatch) { _, index in
                        guard let index, index < matches.count else { return }
                        scroll(to: matches[index].segmentID, in: paragraphs, proxy: proxy, highlight: false)
                    }
                    .onChange(of: navigation.segmentRequest, initial: true) { handleRequest(paragraphs: paragraphs, proxy: proxy) }
                    .onChange(of: paragraphs.isEmpty) { handleRequest(paragraphs: paragraphs, proxy: proxy) }
                    .onChange(of: jumpTarget) { _, target in
                        guard let target else { return }
                        scroll(to: target, in: paragraphs, proxy: proxy, highlight: true)
                        jumpTarget = nil
                    }
            }
        }
        .onChange(of: findText) { currentMatch = matches.isEmpty ? nil : 0 }
        .task(id: meetingID) { await reloadAudio() }
        .onDisappear { player.stop() }
        .exportErrorAlert($exportError)
        .confirmationDialog("Delete this meeting's audio?", isPresented: $confirmDeleteAudio) {
            Button("Delete Audio", role: .destructive) { deleteAudio() }
        } message: {
            Text("The recording is removed from disk now. The transcript and notes are kept, but playback is no longer possible.")
        }
    }

    private func reloadAudio() async {
        player.load(files: (try? await appState.store.audioFiles(meetingID: meetingID)) ?? [])
    }

    private func deleteAudio() {
        let store = appState.store
        let id = meetingID
        deletingAudio = true
        Task {
            defer { deletingAudio = false }
            do {
                // The post-meeting pipeline still reads the files while processing.
                if try await store.meeting(id: id)?.status == .processing {
                    exportError = "Audio can be deleted once processing has finished."
                    return
                }
                player.stop()
                try await RetentionSweeper(store: store).deleteAudioNow(meetingID: id)
            } catch {
                exportError = "Could not delete audio: \(error.localizedDescription)"
            }
            await reloadAudio()
        }
    }

    /// Paragraph rows; ⌘-/⇧-click selects several for Copy selection.
    private func transcript(paragraphs: [TranscriptParagraph], matches: [TranscriptFindMatch]) -> some View {
        List(selection: $selection) {
            ForEach(paragraphs) { paragraph in
                row(paragraph, matches: matches)
                    .tag(paragraph.id)
                    .id(paragraph.id)
            }
        }
        .overlay {
            if paragraphs.isEmpty {
                Text("No transcript yet.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(paragraphs: [TranscriptParagraph], matches: [TranscriptFindMatch]) -> some View {
        HStack(spacing: 8) {
            TextField("Find", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .focused($findFocused)
                .onSubmit { step(backwards: false, count: matches.count) }
            Text(matchStatus(matches.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                step(backwards: true, count: matches.count)
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Previous match (⇧⌘G)")
            .disabled(matches.isEmpty)
            Button {
                step(backwards: false, count: matches.count)
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .help("Next match (⌘G)")
            .disabled(matches.isEmpty)
            Button("Find") { findFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

            TextField("Jump to time", text: $jumpText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .foregroundStyle(jumpError ? .red : .primary)
                .onSubmit { jump(in: paragraphs) }
                .help("hh:mm:ss, mm:ss or seconds")
            Spacer()
            Toggle("Show echo duplicates", isOn: $showEcho).toggleStyle(.checkbox)
            if player.isPlaying {
                Button {
                    player.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else if !player.isAvailable {
                Text("Audio deleted").font(.caption).foregroundStyle(.secondary)
            }
            Menu("Copy") {
                Button("Copy all") { copy(paragraphs) }
                Button("Copy selection") { copy(paragraphs.filter { selection.contains($0.id) }) }
                    .disabled(selection.isEmpty)
            }
            .fixedSize()
            Menu("Export") {
                Button("Export Transcript…") {
                    let store = appState.store
                    Task { exportError = await MeetingExportActions.exportTranscript(meetingID: meetingID, store: store) }
                }
                Divider()
                Button("Delete Audio Now…", role: .destructive) { confirmDeleteAudio = true }
                    .disabled(!player.isAvailable || deletingAudio)
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func matchStatus(_ count: Int) -> String {
        guard !findText.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        guard count > 0 else { return "No matches" }
        return "\((currentMatch ?? 0) + 1) of \(count)"
    }

    private func step(backwards: Bool, count: Int) {
        currentMatch = TranscriptFind.step(from: currentMatch, count: count, backwards: backwards)
    }

    private func jump(in paragraphs: [TranscriptParagraph]) {
        guard let ms = TranscriptTime.parse(jumpText) else {
            jumpError = true
            return
        }
        jumpError = false
        jumpTarget = TranscriptTime.segment(at: ms, in: paragraphs.flatMap(\.segments))?.id
    }

    private func copy(_ paragraphs: [TranscriptParagraph]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(TranscriptGrouping.plainText(paragraphs, participants: participants), forType: .string)
    }

    // MARK: Navigation

    private func handleRequest(paragraphs: [TranscriptParagraph], proxy: ScrollViewProxy) {
        guard let request = navigation.segmentRequest, request.token != handledRequest,
              paragraphs.contains(where: { $0.contains(segmentID: request.segmentID) })
        else { return }
        handledRequest = request.token
        scroll(to: request.segmentID, in: paragraphs, proxy: proxy, highlight: true)
    }

    private func scroll(to segmentID: Int64, in paragraphs: [TranscriptParagraph], proxy: ScrollViewProxy, highlight: Bool) {
        guard let paragraph = paragraphs.first(where: { $0.contains(segmentID: segmentID) }) else { return }
        withAnimation { proxy.scrollTo(paragraph.id, anchor: .center) }
        guard highlight else { return }
        selection = [paragraph.id]
        highlightedSegmentID = segmentID
        Task {
            try? await Task.sleep(for: .seconds(3))
            if highlightedSegmentID == segmentID { highlightedSegmentID = nil }
        }
    }

    // MARK: Rows

    private func row(_ paragraph: TranscriptParagraph, matches: [TranscriptFindMatch]) -> some View {
        let speaker = paragraph.segments.first.map { TranscriptFormatter.speakerName(for: $0, participants: participants) } ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if player.isAvailable {
                Button(TranscriptFormatter.timestamp(ms: paragraph.tStartMs)) {
                    player.play(fromMs: paragraph.tStartMs)
                }
                .buttonStyle(.link)
                .font(.callout.monospacedDigit())
                .help("Play from here")
            } else {
                Text(TranscriptFormatter.timestamp(ms: paragraph.tStartMs))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(speaker) { speakerPopover = paragraph.id }
                .buttonStyle(.link)
                .foregroundStyle(.primary)
                .fontWeight(.semibold)
                .help("Rename, merge or reassign this speaker")
                .popover(isPresented: Binding(
                    get: { speakerPopover == paragraph.id },
                    set: { if !$0 { speakerPopover = nil } }
                )) {
                    SpeakerEditor(
                        meetingID: meetingID, paragraph: paragraph, speaker: speaker, participants: participants,
                        dismiss: { speakerPopover = nil })
                }
            Image(systemName: paragraph.channel == .mic ? "mic" : "speaker.wave.2")
                .foregroundStyle(.secondary)
                .accessibilityLabel(paragraph.channel == .mic ? "Microphone" : "System audio")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(paragraph.segments) { segment in
                    segmentView(segment, matches: matches)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment, matches: [TranscriptFindMatch]) -> some View {
        if let id = segment.id, editingSegmentID == id {
            TextField("Segment text", text: $editText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($editFocused)
                .onSubmit { commitEdit(segment) }
                .onExitCommand { editingSegmentID = nil }
                .onChange(of: editFocused) { _, focused in if !focused, editingSegmentID == id { commitEdit(segment) } }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(highlighted(segment, matches: matches))
                    .italic(segment.isVolatile)
                    .opacity(segment.isVolatile ? 0.6 : 1)
                    .strikethrough(segment.isEchoDuplicate, color: .secondary)
                    .background(highlightedSegmentID == segment.id ? Color.yellow.opacity(0.35) : .clear)
                    .onTapGesture(count: 2) { beginEdit(segment) }
                if segment.editedAt != nil {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Original: \(segment.textOriginal ?? "")")
                        .accessibilityLabel("Edited. Original: \(segment.textOriginal ?? "")")
                }
            }
        }
    }

    private func highlighted(_ segment: Segment, matches: [TranscriptFindMatch]) -> AttributedString {
        let text = segment.text
        let ranges = matches.enumerated().filter { $0.element.segmentID == segment.id }
        guard !ranges.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = 0
        let characters = Array(text)
        for (index, match) in ranges {
            let range = match.range.clamped(to: 0..<characters.count)
            if range.lowerBound > cursor { result += AttributedString(String(characters[cursor..<range.lowerBound])) }
            var piece = AttributedString(String(characters[range]))
            piece.backgroundColor = index == currentMatch ? .orange : .yellow.opacity(0.5)
            result += piece
            cursor = range.upperBound
        }
        if cursor < characters.count { result += AttributedString(String(characters[cursor...])) }
        return result
    }

    private func beginEdit(_ segment: Segment) {
        guard let id = segment.id, !segment.isVolatile else { return }
        editText = segment.text
        editingSegmentID = id
        editFocused = true
    }

    private func commitEdit(_ segment: Segment) {
        guard let id = segment.id, editingSegmentID == id else { return }
        editingSegmentID = nil
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != segment.text else { return }
        let store = appState.store
        let meetingID = meetingID
        Task {
            try? await store.updateSegmentText(id: id, text: text)
            try? await store.reindexFTS(meetingID: meetingID)
        }
    }
}
