import AppKit
import LapCatCore
import UniformTypeIdentifiers
import os

/// The Export menu's actions: copy notes to the pasteboard, or save the meeting document or its
/// transcript through a save panel. Failures are returned as a message for the caller to show.
@MainActor
enum MeetingExportActions {
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "MeetingExportActions")

    enum CopyKind { case markdown, plainText }

    static func copyNotes(meetingID: String, as kind: CopyKind, store: Store) async -> String? {
        do {
            let export = try await MeetingExport.load(meetingID: meetingID, store: store)
            let text = kind == .markdown ? MarkdownExporter.notes(export) : MarkdownExporter.plainText(export)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return nil
        } catch {
            return failure("copy notes", error)
        }
    }

    /// "Export meeting (.md)…": frontmatter + enhanced notes + my notes + transcript.
    static func exportMeeting(meetingID: String, store: Store) async -> String? {
        do {
            let export = try await MeetingExport.load(meetingID: meetingID, store: store)
            let panel = NSSavePanel()
            panel.title = "Export Meeting"
            panel.nameFieldStringValue = MarkdownExporter.fileName(for: export.meeting, fileExtension: "md")
            panel.allowedContentTypes = [contentType(extension: "md")]
            panel.canCreateDirectories = true
            guard await present(panel) == .OK, let url = panel.url else { return nil }
            try MarkdownExporter.bundle(export).write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return failure("export meeting", error)
        }
    }

    /// "Export transcript…": a save panel with a Format popup (Markdown, plain text, SRT, WebVTT)
    /// that keeps the file name's extension in step with the chosen format.
    static func exportTranscript(meetingID: String, store: Store) async -> String? {
        do {
            let export = try await MeetingExport.load(meetingID: meetingID, store: store)
            let panel = NSSavePanel()
            panel.title = "Export Transcript"
            panel.canCreateDirectories = true
            let formatPicker = TranscriptFormatPicker(panel: panel, meeting: export.meeting)
            panel.accessoryView = formatPicker.view
            guard await present(panel) == .OK, let url = panel.url else { return nil }
            try MarkdownExporter.transcript(export, format: formatPicker.format).write(
                to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return failure("export transcript", error)
        }
    }

    /// Shows the panel as a sheet on the key window (else as its own window) and waits for it.
    private static func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
    }

    fileprivate static func contentType(extension ext: String) -> UTType {
        UTType(filenameExtension: ext) ?? .plainText
    }

    private static func failure(_ action: String, _ error: Error) -> String {
        logger.error("\(action, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        return "Could not \(action): \(error.localizedDescription)"
    }
}

extension TranscriptExportFormat {
    var displayName: String {
        switch self {
        case .md: "Markdown (.md)"
        case .txt: "Plain text (.txt)"
        case .srt: "SubRip subtitles (.srt)"
        case .vtt: "WebVTT subtitles (.vtt)"
        }
    }
}

/// The save panel's "Format:" accessory popup.
@MainActor
private final class TranscriptFormatPicker: NSObject {
    let view: NSView
    private(set) var format: TranscriptExportFormat = .md
    private let panel: NSSavePanel
    private let popup: NSPopUpButton

    init(panel: NSSavePanel, meeting: Meeting) {
        self.panel = panel
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: TranscriptExportFormat.allCases.map(\.displayName))
        popup.setAccessibilityLabel("Format")
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(formatChanged)
        panel.nameFieldStringValue = MarkdownExporter.fileName(for: meeting, fileExtension: format.fileExtension)
        apply()
    }

    @objc private func formatChanged() {
        format = TranscriptExportFormat.allCases[max(0, popup.indexOfSelectedItem)]
        let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(stem).\(format.fileExtension)"
        apply()
    }

    private func apply() {
        panel.allowedContentTypes = [MeetingExportActions.contentType(extension: format.fileExtension)]
    }
}
