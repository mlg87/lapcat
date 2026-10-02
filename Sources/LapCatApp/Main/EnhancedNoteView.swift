import AppKit
import LapCatCore
import SwiftUI

/// The Enhanced tab: a version picker, the selected note rendered line by line (the user's own
/// lines in primary, AI lines in secondary), citation links that reveal the transcript segment,
/// Re-enhance and Copy as Markdown.
struct EnhancedNoteView: View {
    let meetingID: String
    let enhancing: Bool
    let enhance: (String, String?) -> Void
    @Environment(AppState.self) private var appState
    @Environment(MeetingNavigation.self) private var navigation
    @State private var notes: [EnhancedNote] = []
    @State private var selectedID: Int64?
    @State private var rawNote = ""
    @State private var templateNames: [String: String] = [:]

    private var selected: EnhancedNote? {
        notes.first { $0.id == selectedID } ?? notes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let note = selected {
                header(note)
                Divider()
                ScrollView {
                    EnhancedMarkdown(markdown: note.markdown, kinds: LineAttribution.classify(enhanced: note.markdown, raw: rawNote))
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .environment(\.openURL, OpenURLAction { url in
                    guard let action = CitationLinkAction(url: url, currentMeetingID: meetingID) else { return .systemAction }
                    navigation.handle(action)
                    return .handled
                })
            } else {
                VStack(spacing: 12) {
                    Text("No enhanced notes yet — End the meeting or press Enhance.")
                        .foregroundStyle(.secondary)
                    if enhancing { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: meetingID) {
            for await notes in appState.store.observeEnhancedNotes(meetingID: meetingID) {
                if notes.first?.id != self.notes.first?.id { selectedID = notes.first?.id }  // a new version shows itself
                self.notes = notes
                rawNote = (try? await appState.store.rawNote(meetingID: meetingID))?.markdown ?? ""
            }
        }
        .task {
            let templates = (try? await appState.store.templates()) ?? []
            templateNames = Dictionary(templates.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func header(_ note: EnhancedNote) -> some View {
        HStack(spacing: 10) {
            Picker("Version", selection: Binding(get: { note.id }, set: { selectedID = $0 })) {
                ForEach(notes) { version in
                    Text(EnhancedNoteLabel.label(for: version, templateName: templateNames[version.templateID]))
                        .tag(version.id)
                }
            }
            .fixedSize()
            Spacer()
            if enhancing {
                ProgressView().controlSize(.small)
                Text("Enhancing…").foregroundStyle(.secondary)
            } else {
                EnhanceMenu(title: "Re-enhance", enhance: enhance)
            }
            Button("Copy as Markdown") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(note.markdown, forType: .string)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Markdown rendered one line at a time: `Text` renders inline Markdown only, so headings and
/// list markers are laid out here; `[[s:ID]]` citations become `lapcat://` links.
private struct EnhancedMarkdown: View {
    let markdown: String
    let kinds: [LineKind]

    var body: some View {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                lineView(MarkdownLine.parse(line), kind: index < kinds.count ? kinds[index] : .ai)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func lineView(_ line: MarkdownLine, kind: LineKind) -> some View {
        let style: HierarchicalShapeStyle = kind == .mine ? .primary : .secondary
        switch line.kind {
        case .blank:
            Spacer().frame(height: 4)
        case .heading(let level):
            inline(line.content)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .foregroundStyle(.primary)
                .padding(.top, 6)
        case .bullet(let depth, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square" : "square")
                } else {
                    Text("•")
                }
                inline(line.content)
            }
            .foregroundStyle(style)
            .padding(.leading, CGFloat(depth) * 18)
        case .numbered(let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit()
                inline(line.content)
            }
            .foregroundStyle(style)
            .padding(.leading, CGFloat(depth) * 18)
        case .text:
            inline(line.content).foregroundStyle(style)
        }
    }

    private func inline(_ content: String) -> Text {
        let linked = Citations.linkified(content)
        let attributed = (try? AttributedString(
            markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(content)
        return Text(attributed)
    }
}
