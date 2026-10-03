import Foundation

/// Recognises Zoom and Google Meet join links in calendar fields and browser tabs.
public enum MeetingURLMatcher {
    public enum Platform: String, Sendable {
        case zoom, meet
    }

    // Zoom: any subdomain of zoom.us (`acme.zoom.us`, `us02web.zoom.us`), `/j/<meeting number>`, optional query (`?pwd=…`).
    private static let zoom = try! NSRegularExpression(
        pattern: #"https://(?:[A-Za-z0-9-]+\.)*zoom\.us/j/\d+(?:\?[^\s<>"'()\[\]]*)?"#)
    // Meet: the `abc-defg-hij` meeting code only (not `/landing`, `/new`, …).
    private static let meet = try! NSRegularExpression(
        pattern: #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z-])"#)
    private static let meetTab = try! NSRegularExpression(
        pattern: #"^https://meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})(?:[/?#]|$)"#)

    /// The conference link of a calendar event: the event URL when it is a meeting link,
    /// else the first meeting link in the notes, else in the location.
    public static func conferenceURL(url: URL?, notes: String?, location: String?) -> URL? {
        for text in [url?.absoluteString, notes, location] {
            if let text, let match = firstMeetingURL(in: text) { return match }
        }
        return nil
    }

    /// The earliest Zoom or Meet join link in free text (HTML notes included).
    public static func firstMeetingURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        let matches = [zoom, meet].compactMap { $0.firstMatch(in: text, range: range) }
        guard let first = matches.min(by: { $0.range.location < $1.range.location }),
            let swiftRange = Range(first.range, in: text)
        else { return nil }
        return URL(string: String(text[swiftRange]))
    }

    public static func platform(of url: URL) -> Platform? {
        let text = url.absoluteString
        let range = NSRange(text.startIndex..., in: text)
        if zoom.firstMatch(in: text, options: .anchored, range: range) != nil { return .zoom }
        if meet.firstMatch(in: text, options: .anchored, range: range) != nil { return .meet }
        return nil
    }

    /// The meeting code (`abc-defg-hij`) when `url` is a Google Meet call tab, else nil.
    public static func meetCode(inTab url: URL) -> String? {
        let text = url.absoluteString
        let range = NSRange(text.startIndex..., in: text)
        guard let match = meetTab.firstMatch(in: text, range: range),
            let code = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[code])
    }

    public static func isMeetCallTab(_ url: URL) -> Bool { meetCode(inTab: url) != nil }
}
