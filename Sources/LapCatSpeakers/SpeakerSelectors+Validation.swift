import Foundation

public enum SpeakerSelectorsValidationError: Error, Equatable, LocalizedError {
    case invalidJSON(String)
    case invalidPattern(field: String, pattern: String)
    case invalidMaxDepth(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let reason): "Not valid selector JSON: \(reason)"
        case .invalidPattern(let field, let pattern): "\(field): “\(pattern)” is not a valid regular expression"
        case .invalidMaxDepth(let depth): "maxDepth must be at least 1 (got \(depth))"
        }
    }
}

extension SpeakerSelectors {
    /// Strict counterpart of `decode(json:fallback:)` for the settings editor: the JSON must decode
    /// and every pattern must compile, otherwise the error says what is wrong.
    public static func validate(json: String) throws(SpeakerSelectorsValidationError) -> SpeakerSelectors {
        let selectors: SpeakerSelectors
        do {
            selectors = try JSONDecoder().decode(SpeakerSelectors.self, from: Data(json.utf8))
        } catch let error as DecodingError {
            throw .invalidJSON(Self.describe(error))
        } catch {
            throw .invalidJSON(error.localizedDescription)
        }
        guard selectors.maxDepth >= 1 else { throw .invalidMaxDepth(selectors.maxDepth) }
        let patterns: [(String, String?)] =
            [("windowTitlePattern", selectors.windowTitlePattern), ("webAreaURLPattern", selectors.webAreaURLPattern)]
            + selectors.participants.map { ("participants", $0.pattern) }
            + selectors.activeSpeaker.map { ("activeSpeaker", $0.pattern) }
            + selectors.selfName.map { ("selfName", $0.pattern) }
        for case let (field, pattern?) in patterns where (try? NSRegularExpression(pattern: pattern)) == nil {
            throw .invalidPattern(field: field, pattern: pattern)
        }
        return selectors
    }

    /// Pretty-printed JSON with sorted keys: the editor's starting text.
    public var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "" : " at \(keys.joined(separator: "."))"
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing key “\(key.stringValue)”\(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(context.debugDescription)\(path(context))"
        case .dataCorrupted(let context):
            return (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
                ?? context.debugDescription
        @unknown default: return error.localizedDescription
        }
    }
}
