import Foundation

/// The sidebar's organisation filters (folder, starred, date range, person), composed with the
/// search text into the `MeetingFilter` the meeting list queries.
public struct MeetingListFilter: Sendable, Equatable {
    public enum DateScope: String, CaseIterable, Sendable {
        case any, today, last7Days, last30Days, custom

        public var label: String {
            switch self {
            case .any: "Any time"
            case .today: "Today"
            case .last7Days: "Last 7 days"
            case .last30Days: "Last 30 days"
            case .custom: "Custom range"
            }
        }
    }

    public var folderID: String?
    public var starredOnly: Bool
    public var dateScope: DateScope
    /// Days of the custom range (inclusive, whole days); used only when `dateScope == .custom`.
    public var customStart: Date
    public var customEnd: Date
    public var personName: String

    /// Searches shorter than this list everything (one character matches too much to be useful).
    public static let minimumSearchLength = 2

    public init(
        folderID: String? = nil, starredOnly: Bool = false, dateScope: DateScope = .any,
        customStart: Date = Date(), customEnd: Date = Date(), personName: String = ""
    ) {
        self.folderID = folderID
        self.starredOnly = starredOnly
        self.dateScope = dateScope
        self.customStart = customStart
        self.customEnd = customEnd
        self.personName = personName
    }

    /// True when any filter other than the folder is set (the folder shows in the sidebar itself).
    public var hasRefinements: Bool {
        starredOnly || dateScope != .any || !trimmedPerson.isEmpty
    }

    public var isActive: Bool { folderID != nil || hasRefinements }

    public func meetingFilter(search: String, now: Date = Date(), calendar: Calendar = .current) -> MeetingFilter {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingFilter(
            search: query.count >= Self.minimumSearchLength ? query : nil,
            folderID: folderID,
            starredOnly: starredOnly,
            dateRange: dateRange(now: now, calendar: calendar),
            personName: trimmedPerson.isEmpty ? nil : trimmedPerson)
    }

    /// Whole calendar days: from the start of the first day to the last instant of the last day.
    public func dateRange(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date>? {
        let today = calendar.startOfDay(for: now)
        func endOfDay(_ date: Date) -> Date {
            calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: date)) ?? date
        }
        func daysBack(_ days: Int) -> ClosedRange<Date> {
            (calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today)...endOfDay(now)
        }
        switch dateScope {
        case .any: return nil
        case .today: return today...endOfDay(now)
        case .last7Days: return daysBack(7)
        case .last30Days: return daysBack(30)
        case .custom:
            let (from, to) = customStart <= customEnd ? (customStart, customEnd) : (customEnd, customStart)
            return calendar.startOfDay(for: from)...endOfDay(to)
        }
    }

    private var trimmedPerson: String { personName.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The header's comma-separated tag editor.
public enum TagList {
    /// Comma-separated names → trimmed, non-empty names, first occurrence wins (case-insensitive).
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").compactMap { part in
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }

    public static func format(_ names: [String]) -> String { names.joined(separator: ", ") }
}
