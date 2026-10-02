import Foundation
import GRDB

public struct Participant: LapCatRecord, MutablePersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "participant"

    public var id: Int64?
    public var meetingID: String
    public var displayName: String
    public var email: String?
    public var source: ParticipantSource
    public var isMe: Bool
    public var clusterLabel: String?
    public var voiceprintID: Int64?

    public init(
        id: Int64? = nil,
        meetingID: String,
        displayName: String,
        email: String? = nil,
        source: ParticipantSource,
        isMe: Bool = false,
        clusterLabel: String? = nil,
        voiceprintID: Int64? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.displayName = displayName
        self.email = email
        self.source = source
        self.isMe = isMe
        self.clusterLabel = clusterLabel
        self.voiceprintID = voiceprintID
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, email, source
        case meetingID = "meeting_id"
        case displayName = "display_name"
        case isMe = "is_me"
        case clusterLabel = "cluster_label"
        case voiceprintID = "voiceprint_id"
    }
}

public struct SpeakerEvent: LapCatRecord, MutablePersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "speaker_event"

    public var id: Int64?
    public var meetingID: String
    public var tStartMs: Int
    public var tEndMs: Int?
    public var displayName: String
    public var source: SpeakerEventSource

    public init(id: Int64? = nil, meetingID: String, tStartMs: Int, tEndMs: Int? = nil, displayName: String, source: SpeakerEventSource) {
        self.id = id
        self.meetingID = meetingID
        self.tStartMs = tStartMs
        self.tEndMs = tEndMs
        self.displayName = displayName
        self.source = source
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, source
        case meetingID = "meeting_id"
        case tStartMs = "t_start_ms"
        case tEndMs = "t_end_ms"
        case displayName = "display_name"
    }
}

public struct Segment: LapCatRecord, MutablePersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "segment"
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }

    public var id: Int64?
    public var meetingID: String
    public var channel: Channel
    public var tStartMs: Int
    public var tEndMs: Int
    public var text: String
    public var textOriginal: String?
    public var participantID: Int64?
    public var clusterLabel: String?
    public var confidence: Double?
    public var pass: SegmentPass
    public var isVolatile: Bool
    public var isEchoDuplicate: Bool
    public var editedAt: Date?

    public init(
        id: Int64? = nil,
        meetingID: String,
        channel: Channel,
        tStartMs: Int,
        tEndMs: Int,
        text: String,
        textOriginal: String? = nil,
        participantID: Int64? = nil,
        clusterLabel: String? = nil,
        confidence: Double? = nil,
        pass: SegmentPass,
        isVolatile: Bool = false,
        isEchoDuplicate: Bool = false,
        editedAt: Date? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.channel = channel
        self.tStartMs = tStartMs
        self.tEndMs = tEndMs
        self.text = text
        self.textOriginal = textOriginal
        self.participantID = participantID
        self.clusterLabel = clusterLabel
        self.confidence = confidence
        self.pass = pass
        self.isVolatile = isVolatile
        self.isEchoDuplicate = isEchoDuplicate
        self.editedAt = editedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, channel, text, confidence, pass
        case meetingID = "meeting_id"
        case tStartMs = "t_start_ms"
        case tEndMs = "t_end_ms"
        case textOriginal = "text_original"
        case participantID = "participant_id"
        case clusterLabel = "cluster_label"
        case isVolatile = "is_volatile"
        case isEchoDuplicate = "is_echo_duplicate"
        case editedAt = "edited_at"
    }
}

public struct Voiceprint: LapCatRecord, MutablePersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "voiceprint"
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }

    public var id: Int64?
    public var participantName: String
    public var embedding: Data
    public var createdAt: Date

    public init(id: Int64? = nil, participantName: String, embedding: Data, createdAt: Date) {
        self.id = id
        self.participantName = participantName
        self.embedding = embedding
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, embedding
        case participantName = "participant_name"
        case createdAt = "created_at"
    }
}
