import Foundation
import GRDB

public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    case recording, processing, ready, error
}

public enum MeetingStartedBy: String, Codable, Sendable {
    case manual, prompt
}

/// Audio channel of a segment: `mic` = Me, `system` = Them.
public enum Channel: String, Codable, Sendable, CaseIterable {
    case mic, system
}

public enum SegmentPass: String, Codable, Sendable {
    case live, final
}

public enum ParticipantSource: String, Codable, Sendable {
    case calendar
    case zoomAX = "zoom_ax"
    case meetAX = "meet_ax"
    case manual
    case llmSuggested = "llm_suggested"
    case cluster
}

public enum SpeakerEventSource: String, Codable, Sendable {
    case zoomAX = "zoom_ax"
    case meetAX = "meet_ax"
}

public enum ChatScope: String, Codable, Sendable {
    case meeting, folder, global
}

public enum ChatRole: String, Codable, Sendable {
    case user, assistant
}

/// Kinds of rows in `fts_content`.
public enum SearchKind: String, Codable, Sendable {
    case segment, raw, enhanced, title, person
}

/// Conformances shared by every record. Records with `Date` columns declare
/// `databaseDate{De,En}codingStrategy(for:)` = `.timeIntervalSince1970` themselves (REAL columns in the DDL):
/// a default in an extension of this protocol is not picked as the witness.
public protocol LapCatRecord: Codable, Sendable, FetchableRecord, EncodableRecord {}
