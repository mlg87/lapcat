import Foundation

// Pure helpers behind the search results list and the chat input (plan §10.1, §10.4).

public enum SearchSnippet {
    /// An FTS snippet (`snippet(…, '<b>', '</b>', …)`) as display text: `<b>…</b>` runs become strongly
    /// emphasized (bold), the tags are removed, and runs of whitespace (newlines included) collapse to one space.
    /// An unclosed `<b>` emphasizes to the end; a stray `</b>` is dropped.
    public static func attributed(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        var rest = Substring(snippet)
        while !rest.isEmpty {
            let tag = bold ? "</b>" : "<b>"
            let stray = bold ? "<b>" : "</b>"
            let next = rest.range(of: tag)
            let chunkEnd = next?.lowerBound ?? rest.endIndex
            let chunk = String(rest[..<chunkEnd]).replacingOccurrences(of: stray, with: "")
            if !chunk.isEmpty {
                var piece = AttributedString(chunk)
                if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
                result += piece
            }
            guard let next else { break }
            bold.toggle()
            rest = rest[next.upperBound...]
        }
        return collapsingWhitespace(result)
    }

    private static func collapsingWhitespace(_ text: AttributedString) -> AttributedString {
        var output = AttributedString()
        var previousWasSpace = true  // also trims leading whitespace
        for run in text.runs {
            var piece = ""
            for character in String(text[run.range].characters) {
                if character.isWhitespace {
                    if !previousWasSpace { piece.append(" ") }
                    previousWasSpace = true
                } else {
                    piece.append(character)
                    previousWasSpace = false
                }
            }
            guard !piece.isEmpty else { continue }
            var attributed = AttributedString(piece)
            attributed.inlinePresentationIntent = run.inlinePresentationIntent
            output += attributed
        }
        while let last = output.characters.last, last == " " {
            output.removeSubrange(output.index(beforeCharacter: output.endIndex)..<output.endIndex)
        }
        return output
    }
}

extension SearchKind {
    /// Badge text in the search results list.
    public var badgeLabel: String {
        switch self {
        case .segment: "transcript"
        case .raw: "notes"
        case .enhanced: "enhanced"
        case .person: "person"
        case .title: "title"
        }
    }
}

/// Where selecting a search hit takes the main window.
public enum SearchHitTarget: Equatable, Sendable {
    /// The Transcript tab scrolled to the segment.
    case transcript(segmentID: Int64)
    case notes
    case enhanced
    /// The meeting with its default tab (title and person hits).
    case meeting

    public init(_ hit: SearchHit) {
        switch hit.kind {
        case .segment: self = Int64(hit.refID).map { .transcript(segmentID: $0) } ?? .meeting
        case .raw: self = .notes
        case .enhanced: self = .enhanced
        case .title, .person: self = .meeting
        }
    }
}

extension SearchHit: Identifiable {
    public var id: String { "\(meetingID)|\(kind.rawValue)|\(refID)" }
}

/// The `/` recipe picker of the chat input.
public enum RecipeFilter {
    /// Recipes whose slash command starts with what is typed, while the input is a slash command being typed
    /// (starts with `/`, no whitespace); nil otherwise, i.e. the picker is hidden. Case-insensitive; order kept.
    public static func suggestions(for input: String, in recipes: [Recipe]) -> [Recipe]? {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard typed.hasPrefix("/"), !typed.contains(where: \.isWhitespace) else { return nil }
        return recipes.filter { $0.slashCommand.lowercased().hasPrefix(typed) }
    }

    /// The recipe whose slash command is exactly the input (surrounding whitespace ignored, case-insensitive).
    public static func recipe(matching input: String, in recipes: [Recipe]) -> Recipe? {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recipes.first { $0.slashCommand.lowercased() == typed }
    }
}
