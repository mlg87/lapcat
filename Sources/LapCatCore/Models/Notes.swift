import Foundation
import GRDB

public struct RawNote: LapCatRecord, PersistableRecord, Hashable {
    public static let databaseTableName = "raw_note"
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public var meetingID: String
    public var markdown: String
    public var updatedAt: Date

    public init(meetingID: String, markdown: String, updatedAt: Date) {
        self.meetingID = meetingID
        self.markdown = markdown
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case markdown
        case meetingID = "meeting_id"
        case updatedAt = "updated_at"
    }
}

public struct EnhancedNote: LapCatRecord, MutablePersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "enhanced_note"
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public var id: Int64?
    public var meetingID: String
    public var version: Int
    public var templateID: String
    public var provider: String
    public var model: String
    public var markdown: String
    public var citationsJSON: String
    public var basedOnPass: SegmentPass
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        meetingID: String,
        version: Int = 0,
        templateID: String,
        provider: String,
        model: String,
        markdown: String,
        citationsJSON: String = "[]",
        basedOnPass: SegmentPass,
        createdAt: Date
    ) {
        self.id = id
        self.meetingID = meetingID
        self.version = version
        self.templateID = templateID
        self.provider = provider
        self.model = model
        self.markdown = markdown
        self.citationsJSON = citationsJSON
        self.basedOnPass = basedOnPass
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, version, provider, model, markdown
        case meetingID = "meeting_id"
        case templateID = "template_id"
        case citationsJSON = "citations_json"
        case basedOnPass = "based_on_pass"
        case createdAt = "created_at"
    }
}

public struct Template: LapCatRecord, PersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "template"
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public var id: String
    public var name: String
    public var description: String
    public var bodyMarkdown: String
    public var isBuiltin: Bool
    public var filePath: String?
    public var updatedAt: Date

    public init(
        id: String, name: String, description: String = "", bodyMarkdown: String, isBuiltin: Bool,
        filePath: String? = nil, updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.bodyMarkdown = bodyMarkdown
        self.isBuiltin = isBuiltin
        self.filePath = filePath
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case bodyMarkdown = "body_markdown"
        case isBuiltin = "is_builtin"
        case filePath = "file_path"
        case updatedAt = "updated_at"
    }
}

public struct Recipe: LapCatRecord, PersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "recipe"

    public var id: String
    public var name: String
    public var slashCommand: String
    public var prompt: String
    public var isBuiltin: Bool

    public init(id: String, name: String, slashCommand: String, prompt: String, isBuiltin: Bool) {
        self.id = id
        self.name = name
        self.slashCommand = slashCommand
        self.prompt = prompt
        self.isBuiltin = isBuiltin
    }

    enum CodingKeys: String, CodingKey {
        case id, name, prompt
        case slashCommand = "slash_command"
        case isBuiltin = "is_builtin"
    }
}

public struct ChatThread: LapCatRecord, PersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "chat_thread"
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public var id: String
    public var scope: ChatScope
    /// Meeting id for `.meeting`, folder id for `.folder`, nil for `.global`.
    public var scopeRef: String?
    public var title: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString, scope: ChatScope, scopeRef: String?, title: String? = nil, createdAt: Date
    ) {
        self.id = id
        self.scope = scope
        self.scopeRef = scopeRef
        self.title = title
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, scope, title
        case scopeRef = "scope_ref"
        case createdAt = "created_at"
    }
}

public struct ChatMessage: LapCatRecord, MutablePersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "chat_message"
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public var id: Int64?
    public var threadID: String
    public var role: ChatRole
    public var content: String
    public var citationsJSON: String
    public var provider: String?
    public var model: String?
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        threadID: String,
        role: ChatRole,
        content: String,
        citationsJSON: String = "[]",
        provider: String? = nil,
        model: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.content = content
        self.citationsJSON = citationsJSON
        self.provider = provider
        self.model = model
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, role, content, provider, model
        case threadID = "thread_id"
        case citationsJSON = "citations_json"
        case createdAt = "created_at"
    }
}

public struct Folder: LapCatRecord, PersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "folder"

    public var id: String
    public var name: String
    public var sortOrder: Int

    public init(id: String = UUID().uuidString, name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case sortOrder = "sort_order"
    }
}

public struct Tag: LapCatRecord, PersistableRecord, Identifiable, Hashable {
    public static let databaseTableName = "tag"

    public var id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

public struct MeetingTag: LapCatRecord, PersistableRecord, Hashable {
    public static let databaseTableName = "meeting_tag"

    public var meetingID: String
    public var tagID: String

    public init(meetingID: String, tagID: String) {
        self.meetingID = meetingID
        self.tagID = tagID
    }

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case tagID = "tag_id"
    }
}
