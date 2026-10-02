import Foundation

/// Titles LapCat gives meetings that have no calendar event: `Note 2026-10-01 14:05`.
/// Enhance replaces a still-default title with a generated one.
public enum MeetingTitle {
    public static func `default`(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Note " + formatter.string(from: date)
    }

    public static func isDefault(_ title: String) -> Bool {
        title.wholeMatch(of: /Note \d{4}-\d{2}-\d{2} \d{2}:\d{2}/) != nil
    }
}
