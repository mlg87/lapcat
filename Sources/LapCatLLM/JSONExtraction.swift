import Foundation

/// Pulls the JSON object out of an LLM reply that may wrap it in code fences or prose.
public enum JSONExtraction {
    /// The first balanced `{…}` object in `text` that parses as JSON, with ``` fences removed first.
    public static func extract(from text: String) -> Data? {
        let unfenced = stripFences(text)
        var searchStart = unfenced.startIndex
        while let open = unfenced[searchStart...].firstIndex(of: "{") {
            if let close = matchingBrace(in: unfenced, from: open) {
                let data = Data(unfenced[open...close].utf8)
                if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return data }
            }
            searchStart = unfenced.index(after: open)
        }
        return nil
    }

    /// Decodes the extracted object, or nil when there is none or it does not match `T`.
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = extract(from: text) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Removes Markdown code-fence lines (```` ``` ```` and ```` ```json ````), keeping their content.
    static func stripFences(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
    }

    /// Index of the `}` closing the `{` at `open`, skipping braces inside JSON strings.
    private static func matchingBrace(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
