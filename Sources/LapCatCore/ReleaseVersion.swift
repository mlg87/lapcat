import Foundation

/// A `MAJOR.MINOR.PATCH` release version, with or without a leading `v` (`v0.1.2`, `0.1.2`).
/// Components compare numerically, so `0.1.10` is newer than `0.1.9`.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ text: String) {
        let digits = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil
        }
        guard numbers.count == 3 else { return nil }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A published GitHub release of LapCat, as returned by
/// `GET /repos/mlg87/lapcat/releases/latest` (newest release that is not a draft or prerelease).
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public static let repository = "mlg87/lapcat"
    public static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest")!

    public let tag: String
    /// The release notes page on github.com.
    public let notesURL: URL

    public init(tag: String, notesURL: URL) {
        self.tag = tag
        self.notesURL = notesURL
    }

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case notesURL = "html_url"
    }

    /// The release notes page of `version` (`0.1.2` → `…/releases/tag/v0.1.2`).
    public static func notesURL(forVersion version: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
    }

    /// `latest` when its tag is a newer version than `runningVersion`; nil when it is not newer or
    /// either version does not parse.
    public static func update(from latest: GitHubRelease, runningVersion: String) -> GitHubRelease? {
        guard let available = ReleaseVersion(latest.tag), let running = ReleaseVersion(runningVersion),
            available > running
        else { return nil }
        return latest
    }
}
