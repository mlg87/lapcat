import Foundation

/// On-disk layout under `~/Library/Application Support/LapCat/`.
public struct Paths: Sendable {
    public let appSupport: URL

    /// `root` overrides the app-support directory (tests use a temp dir).
    public init(root: URL? = nil) {
        appSupport =
            root
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LapCat", isDirectory: true)
    }

    public static let standard = Paths()

    public var database: URL { appSupport.appendingPathComponent("lapcat.sqlite") }
    public var audioRoot: URL { appSupport.appendingPathComponent("audio", isDirectory: true) }
    public var models: URL { appSupport.appendingPathComponent("models", isDirectory: true) }
    public var templates: URL { appSupport.appendingPathComponent("templates", isDirectory: true) }
    public var exports: URL { appSupport.appendingPathComponent("exports", isDirectory: true) }

    public func audio(meetingID: String) -> URL {
        audioRoot.appendingPathComponent(meetingID, isDirectory: true)
    }

    /// Creates every fixed directory; called on launch.
    public func ensureDirectories() throws {
        for dir in [appSupport, audioRoot, models, templates, exports] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
