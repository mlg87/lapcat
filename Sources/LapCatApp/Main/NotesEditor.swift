import AppKit
import LapCatCore
import SwiftUI

/// The user's raw Markdown notes for a meeting, autosaved 1 s after the last keystroke.
///
/// Backed by an `NSTextView` rather than SwiftUI `TextEditor`: ⌘B (wrap selection in `**`) and
/// list continuation on Enter need the selection and key handling, which `TextEditor` does not
/// expose on macOS 14.
struct NotesEditor: View {
    let meetingID: String
    @Environment(AppState.self) private var appState
    @State private var text = ""
    @State private var savedText = ""
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                MarkdownTextView(text: $text, placeholder: "Type your notes… (⌘B bold, “- ” and “- [ ] ” lists)")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: meetingID) {
            let markdown = (try? await appState.store.rawNote(meetingID: meetingID))?.markdown ?? ""
            text = markdown
            savedText = markdown
            loaded = true
        }
        .task(id: text) {
            guard loaded, text != savedText else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await save()
        }
        .onDisappear {
            guard loaded, text != savedText else { return }
            let store = appState.store
            let meetingID = meetingID
            let text = text
            Task { try? await store.saveRawNote(meetingID: meetingID, markdown: text) }
        }
    }

    private func save() async {
        let snapshot = text
        do {
            try await appState.store.saveRawNote(meetingID: meetingID, markdown: snapshot)
            savedText = snapshot
        } catch {
            // Kept unsaved; the next edit retries.
        }
    }
}

/// Plain-text Markdown editor with ⌘B bold toggling and `- ` / `- [ ] ` list continuation.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NotesTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.placeholder = placeholder
        textView.setAccessibilityLabel("Notes")
        textView.string = text
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }
            let string = textView.string as NSString
            let lineRange = string.lineRange(for: NSRange(location: selection.location, length: 0))
            // Only when the cursor is at the end of the line's content.
            let contentEnd =
                lineRange.location + lineRange.length
                - (string.substring(with: lineRange).hasSuffix("\n") ? 1 : 0)
            guard selection.location == contentEnd else { return false }
            let line = string.substring(
                with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))
            switch MarkdownListContinuation.action(forLine: line) {
            case .continueList(let prefix):
                textView.insertText("\n" + prefix, replacementRange: selection)
                return true
            case .endList:
                textView.insertText(
                    "", replacementRange: NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
                )
                return true
            case nil:
                return false
            }
        }
    }
}

/// Handles ⌘B and draws the placeholder while empty.
final class NotesTextView: NSTextView {
    var placeholder = ""

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "b", window?.firstResponder === self {
            toggleBold()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func toggleBold() {
        let selection = selectedRange()
        let result = MarkdownBold.toggle(string, range: selection)
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: result.text) else { return }
        textStorage?.replaceCharacters(in: full, with: result.text)
        didChangeText()
        setSelectedRange(result.selection)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(
            at: origin,
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.placeholderTextColor,
            ])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
