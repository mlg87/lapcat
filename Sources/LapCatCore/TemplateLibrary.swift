import Foundation
import os

/// A template file: `---` frontmatter with `name:` and `description:`, then Markdown with `##`
/// sections and `<!-- instruction -->` comments for the LLM.
public struct TemplateDocument: Sendable, Equatable {
    public var name: String
    public var description: String
    public var body: String

    /// Parses `text`. Without frontmatter, the whole text is the body and `fallbackName` the name.
    public init(parsing text: String, fallbackName: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var name: String?
        var description = ""
        var bodyStart = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        {
            for line in lines[1..<close] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = Self.unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                switch key {
                case "name": name = value
                case "description": description = value
                default: break
                }
            }
            bodyStart = close + 1
        }
        self.name = (name?.isEmpty ?? true) ? fallbackName : name!
        self.description = description
        body = lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unquote(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// Built-in templates (bundled `Templates/*.md`, id = file stem) and user templates
/// (`*.md` in the templates folder, id = `custom:<stem>`), kept in sync with the `template` table.
public enum TemplateLibrary {
    /// Pseudo-template: the enhancer classifies the meeting and picks a template. Never a row.
    public static let autoID = "auto"
    /// Fallback when `auto` classification fails.
    public static let generalID = "general"
    public static let customPrefix = "custom:"

    private static let logger = Logger(subsystem: "com.lapcat.app", category: "TemplateLibrary")

    /// Where built-in templates are read from (diagnostics).
    public static var resourceBundlePath: String { LapCatCoreResources.bundle.bundlePath }

    /// The templates shipped in LapCatCore's resource bundle.
    public static func builtinTemplates(now: Date = Date()) throws -> [Template] {
        guard let directory = LapCatCoreResources.bundle.url(forResource: "Templates", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Templates missing from \(LapCatCoreResources.bundleName)"])
        }
        return try templates(in: directory, idPrefix: "", isBuiltin: true, now: now)
    }

    /// The user's templates in `directory`; a missing directory means none.
    public static func customTemplates(in directory: URL, now: Date = Date()) throws -> [Template] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try templates(in: directory, idPrefix: customPrefix, isBuiltin: false, now: now)
    }

    /// Upserts built-in and custom templates and deletes rows whose file is gone.
    /// Run at launch and whenever the templates settings open.
    @discardableResult
    public static func sync(store: Store, customDirectory: URL, now: Date = Date()) async throws -> [Template] {
        let builtins = try builtinTemplates(now: now)
        let custom = try customTemplates(in: customDirectory, now: now)
        try await store.replaceTemplates(builtins: builtins, custom: custom)
        return builtins + custom
    }

    private static func templates(in directory: URL, idPrefix: String, isBuiltin: Bool, now: Date) throws -> [Template] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { file in
            let stem = file.deletingPathExtension().lastPathComponent
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                logger.error("Skipping unreadable template \(file.path, privacy: .public)")
                return nil
            }
            let document = TemplateDocument(parsing: text, fallbackName: stem)
            return Template(
                id: idPrefix + stem, name: document.name, description: document.description,
                bodyMarkdown: document.body, isBuiltin: isBuiltin,
                // Under `directory` as given (contentsOfDirectory resolves symlinks such as /var → /private/var).
                filePath: isBuiltin ? nil : directory.appendingPathComponent(file.lastPathComponent).path, updatedAt: now)
        }
    }
}
