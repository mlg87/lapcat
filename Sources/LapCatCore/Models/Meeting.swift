import Foundation
import GRDB

public struct Meeting: LapCatRecord, PersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "meeting"
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus
    public var sourceApp: String
    public var sourceBundleID: String?
    public var sourcePID: Int32?
    public var startedBy: MeetingStartedBy
    public var calendarEventID: String?
    public var folderID: String?
    public var starred: Bool
    public var templateID: String?
    public var llmProviderUsed: String?
    public var audioRetainedUntil: Date?
    public var processingStep: String?
    public var errorMessage: String?
    public var consentConfirmed: Bool
    public var exportPath: String?
    public var createdAt: Date
    public var updatedAt: Date

    /// False while recording or processing: the session or the pipeline still writes to the meeting.
    public var isDeletable: Bool { status == .ready || status == .error }

    public init(
        id: String = UUID().uuidString,
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        status: MeetingStatus = .recording,
        sourceApp: String = "other",
        sourceBundleID: String? = nil,
        sourcePID: Int32? = nil,
        startedBy: MeetingStartedBy,
        calendarEventID: String? = nil,
        folderID: String? = nil,
        starred: Bool = false,
        templateID: String? = nil,
        llmProviderUsed: String? = nil,
        audioRetainedUntil: Date? = nil,
        processingStep: String? = nil,
        errorMessage: String? = nil,
        consentConfirmed: Bool = false,
        exportPath: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.sourcePID = sourcePID
        self.startedBy = startedBy
        self.calendarEventID = calendarEventID
        self.folderID = folderID
        self.starred = starred
        self.templateID = templateID
        self.llmProviderUsed = llmProviderUsed
        self.audioRetainedUntil = audioRetainedUntil
        self.processingStep = processingStep
        self.errorMessage = errorMessage
        self.consentConfirmed = consentConfirmed
        self.exportPath = exportPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, status, starred
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case sourceApp = "source_app"
        case sourceBundleID = "source_bundle_id"
        case sourcePID = "source_pid"
        case startedBy = "started_by"
        case calendarEventID = "calendar_event_id"
        case folderID = "folder_id"
        case templateID = "template_id"
        case llmProviderUsed = "llm_provider_used"
        case audioRetainedUntil = "audio_retained_until"
        case processingStep = "processing_step"
        case errorMessage = "error_message"
        case consentConfirmed = "consent_confirmed"
        case exportPath = "export_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct CalendarSnapshot: LapCatRecord, PersistableRecord, Hashable {
    public static let databaseTableName = "calendar_snapshot"
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public var meetingID: String
    public var eventTitle: String?
    public var organizer: String?
    /// Stored as a JSON array in `attendees_json`.
    public var attendees: [String]
    public var conferenceURL: String?
    public var scheduledStart: Date?
    public var scheduledEnd: Date?

    public init(
        meetingID: String,
        eventTitle: String? = nil,
        organizer: String? = nil,
        attendees: [String] = [],
        conferenceURL: String? = nil,
        scheduledStart: Date? = nil,
        scheduledEnd: Date? = nil
    ) {
        self.meetingID = meetingID
        self.eventTitle = eventTitle
        self.organizer = organizer
        self.attendees = attendees
        self.conferenceURL = conferenceURL
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
    }

    enum CodingKeys: String, CodingKey {
        case organizer
        case meetingID = "meeting_id"
        case eventTitle = "event_title"
        case attendees = "attendees_json"
        case conferenceURL = "conference_url"
        case scheduledStart = "scheduled_start"
        case scheduledEnd = "scheduled_end"
    }
}

public struct AudioFile: LapCatRecord, PersistableRecord, Hashable {
    public static let databaseTableName = "audio_file"

    public var meetingID: String
    public var channel: Channel
    public var path: String
    public var codec: String
    public var durationMs: Int?

    public init(meetingID: String, channel: Channel, path: String, codec: String = "aac-adts", durationMs: Int? = nil) {
        self.meetingID = meetingID
        self.channel = channel
        self.path = path
        self.codec = codec
        self.durationMs = durationMs
    }

    enum CodingKeys: String, CodingKey {
        case channel, path, codec
        case meetingID = "meeting_id"
        case durationMs = "duration_ms"
    }
}
