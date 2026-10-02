import Foundation
import LapCatCore
import LapCatLLM
import Observation

/// Which meeting the main window shows, which tab, and which transcript segment to reveal.
/// Injected with `.environment(navigation)` by `MainWindow`; citations, search hits and chat
/// links navigate through it.
@Observable @MainActor
final class MeetingNavigation {
    enum Tab: Hashable {
        case notes, enhanced, transcript
    }

    /// A one-shot request to scroll the transcript to a segment; a new token re-triggers the same id.
    struct SegmentRequest: Equatable {
        var segmentID: Int64
        var token = UUID()
    }

    /// Changing meetings opens the Transcript tab.
    var selectedMeetingID: String? {
        didSet { if selectedMeetingID != oldValue { tab = .transcript } }
    }
    var tab: Tab = .transcript
    var segmentRequest: SegmentRequest?

    /// Shows the meeting's transcript scrolled to `segmentID`.
    func show(meetingID: String, segmentID: Int64? = nil) {
        selectedMeetingID = meetingID
        if let segmentID { reveal(segmentID: segmentID) }
    }

    /// Switches the current meeting to its Transcript tab at `segmentID`.
    func reveal(segmentID: Int64) {
        tab = .transcript
        segmentRequest = SegmentRequest(segmentID: segmentID)
    }

    func handle(_ action: CitationLinkAction) {
        switch action {
        case .transcriptSegment(let id): reveal(segmentID: id)
        case .otherMeeting(let meetingID, let id): show(meetingID: meetingID, segmentID: id)
        }
    }
}

extension AppState {
    /// Writes a new enhanced-note version. `templateID` is a template id or `TemplateLibrary.autoID`;
    /// `providerID` pins the request to one provider instead of the configured order.
    @discardableResult
    func enhance(meetingID: String, templateID: String, providerID: String?) async throws -> EnhancedNote {
        let note = try await Enhancer(store: store, router: llm.router)
            .enhance(meetingID: meetingID, templateID: templateID, providerOverride: providerID)
        try await store.reindexFTS(meetingID: meetingID)
        return note
    }
}
