import Foundation

/// One way of reading a participant name out of an AX element.
public struct AXNameRule: Codable, Sendable, Hashable {
    public enum Attribute: String, Codable, Sendable {
        case title, description, value, identifier, any
    }

    /// Exact `AXRole` the element must have; nil matches any role.
    public var role: String?
    /// Text attribute the pattern is applied to; `any` tries title, description, value in that order.
    public var attribute: Attribute
    /// Regular expression; capture group 1 (or the whole match when there is none) is the name.
    public var pattern: String

    public init(role: String? = nil, attribute: Attribute, pattern: String) {
        self.role = role
        self.attribute = attribute
        self.pattern = pattern
    }

    /// The name this rule (compiled as `regex`) reads from `node`, or nil.
    func name(in node: AXNodeSnapshot, regex: NSRegularExpression) -> String? {
        if let role, node.role != role { return nil }
        let candidates: [String?] =
            switch attribute {
            case .title: [node.title]
            case .description: [node.description]
            case .value: [node.value]
            case .identifier: [node.identifier]
            case .any: [node.title, node.description, node.value]
            }
        for case let text? in candidates {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            let captured =
                match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                ? match.range(at: 1) : match.range
            guard let swiftRange = Range(captured, in: text) else { continue }
            let name = text[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }
}

/// Where a meeting app's speaker information lives in its accessibility tree.
///
/// Defaults are compiled into each adapter; the app may override them with JSON from the
/// `speakers.selectors.<adapter>` setting so a UI change in Zoom/Meet is a settings edit.
public struct SpeakerSelectors: Codable, Sendable, Hashable {
    /// Windows whose title matches are searched; nil = every window.
    public var windowTitlePattern: String?
    /// When set, `AXWebArea` elements whose `AXURL` matches are used as roots (preferred over windows).
    public var webAreaURLPattern: String?
    public var participants: [AXNameRule]
    public var activeSpeaker: [AXNameRule]
    public var selfName: [AXNameRule]
    /// Tree depth captured per poll.
    public var maxDepth: Int

    public init(
        windowTitlePattern: String? = nil,
        webAreaURLPattern: String? = nil,
        participants: [AXNameRule],
        activeSpeaker: [AXNameRule],
        selfName: [AXNameRule],
        maxDepth: Int
    ) {
        self.windowTitlePattern = windowTitlePattern
        self.webAreaURLPattern = webAreaURLPattern
        self.participants = participants
        self.activeSpeaker = activeSpeaker
        self.selfName = selfName
        self.maxDepth = maxDepth
    }

    /// `json` decoded as selectors, or `fallback` when it is nil, empty or invalid.
    public static func decode(json: String?, fallback: SpeakerSelectors) -> SpeakerSelectors {
        guard let data = json?.data(using: .utf8), !data.isEmpty,
            let decoded = try? JSONDecoder().decode(SpeakerSelectors.self, from: data)
        else { return fallback }
        return decoded
    }

    /// Applies the rules to every node of the captured roots. Names keep first-seen order and are
    /// de-duplicated; the self name is never reported as active, and every active name is a participant.
    public func observation(from roots: [AXNodeSnapshot]) -> SpeakerObservation {
        let nodes = roots.flatMap(\.flattened)
        func names(_ rules: [AXNameRule]) -> [String] {
            let compiled = rules.compactMap { rule in
                (try? NSRegularExpression(pattern: rule.pattern)).map { (rule, $0) }
            }
            var seen = Set<String>()
            var result: [String] = []
            for node in nodes {
                for (rule, regex) in compiled {
                    if let name = rule.name(in: node, regex: regex), seen.insert(name).inserted { result.append(name) }
                }
            }
            return result
        }
        let selfName = names(self.selfName).first
        var participants = names(self.participants)
        let active = names(self.activeSpeaker).filter { $0 != selfName }
        for name in active where !participants.contains(name) { participants.append(name) }
        if let selfName, !participants.contains(selfName) { participants.append(selfName) }
        return SpeakerObservation(activeNames: active, participants: participants, selfName: selfName)
    }
}

extension SpeakerSelectors {
    // UNVERIFIED pending the axdump spike (lc-6bq): these defaults follow Zoom's and Meet's public
    // accessibility labelling, not a recorded dump of a live call. Override via JSON when they miss.

    /// Zoom desktop (`us.zoom.xos`): participant-list rows describe "Name, (Host, me), Computer audio
    /// unmuted, …"; the active-speaker tile is announced as "Name is talking"/"speaking".
    public static let zoomDefault = SpeakerSelectors(
        windowTitlePattern: nil,
        participants: [
            AXNameRule(
                attribute: .any, pattern: #"^(.+?)(?:,\s*\((?:[^)]*)\))?,\s*(?:Computer audio|Telephone|Audio)\b"#)
        ],
        activeSpeaker: [
            AXNameRule(attribute: .any, pattern: #"^(.+?)(?:\s*\((?:[^)]*)\))?\s+is\s+(?:talking|speaking)\b"#),
            AXNameRule(attribute: .any, pattern: #"^Active speaker[:,]?\s*(.+)$"#),
        ],
        selfName: [
            AXNameRule(attribute: .any, pattern: #"^(.+?),?\s*\((?:[^)]*\b)?me\)"#)
        ],
        maxDepth: 20
    )

    /// Google Meet in a browser: tiles expose "More options for Name"; the people panel lists
    /// "Name (You)" for the user; speaking tiles are labelled "Name is speaking" when exposed.
    public static let meetDefault = SpeakerSelectors(
        windowTitlePattern: #"Meet"#,
        webAreaURLPattern: #"^https://meet\.google\.com/"#,
        participants: [
            AXNameRule(attribute: .any, pattern: #"^(?:Show )?[Mm]ore options for (.+)$"#),
            AXNameRule(
                attribute: .any, pattern: #"^(?:Pin|Unpin) (.+?)(?:'s| to your main screen| from your main screen)"#),
        ],
        activeSpeaker: [
            AXNameRule(attribute: .any, pattern: #"^(.+?)\s+is\s+(?:speaking|talking)\b"#)
        ],
        selfName: [
            AXNameRule(attribute: .any, pattern: #"^(.+?)\s*\((?:You|you)\)$"#)
        ],
        maxDepth: 40
    )
}
