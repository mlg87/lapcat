import EventKit
import Foundation

/// A calendar event as LapCat uses it (PRD FR-1.4): title, people and conference link.
public struct CalendarEventInfo: Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var organizer: String?
    public var attendees: [String]
    public var conferenceURL: URL?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool

    public init(
        id: String, title: String, organizer: String? = nil, attendees: [String] = [],
        conferenceURL: URL? = nil, start: Date, end: Date, isAllDay: Bool = false
    ) {
        self.id = id
        self.title = title
        self.organizer = organizer
        self.attendees = attendees
        self.conferenceURL = conferenceURL
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

/// Reads EventKit for the meeting being recorded. Never prompts; without full calendar access
/// every query returns nil.
public final class CalendarService: @unchecked Sendable {
    // EKEventStore is thread-safe for reads; it is never mutated here.
    private let store = EKEventStore()

    public init() {}

    /// Default lookup window around `now`: ±15 minutes.
    public static let defaultWindow: ClosedRange<TimeInterval> = -15 * 60...15 * 60

    /// The event best matching a meeting at `now` within `window` (offsets from `now`, seconds):
    /// see `select(from:now:window:)`. Nil without calendar permission.
    public func currentOrUpcomingEvent(
        window: ClosedRange<TimeInterval> = CalendarService.defaultWindow, now: Date = Date()
    ) -> CalendarEventInfo? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let start = now.addingTimeInterval(min(window.lowerBound, 0))
        let end = now.addingTimeInterval(max(window.upperBound, 0))
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map(Self.info(from:))
        return Self.select(from: events, now: now, window: window)
    }

    /// Picks the event for a meeting at `now`. Candidates are timed (not all-day) events that
    /// overlap `[now + window.lowerBound, now + window.upperBound]`. Preference:
    /// 1. in progress at `now` (the most recently started one when several overlap);
    /// 2. else the one starting soonest after `now`;
    /// 3. else the one that ended most recently (a meeting running over its slot).
    public static func select(
        from events: [CalendarEventInfo], now: Date, window: ClosedRange<TimeInterval>
    ) -> CalendarEventInfo? {
        let lower = now.addingTimeInterval(window.lowerBound)
        let upper = now.addingTimeInterval(window.upperBound)
        let candidates = events.filter { !$0.isAllDay && $0.start <= upper && $0.end >= lower && $0.end > $0.start }

        let inProgress = candidates.filter { $0.start <= now && now < $0.end }
        if let event = inProgress.max(by: { $0.start < $1.start }) { return event }
        let upcoming = candidates.filter { $0.start > now }
        if let event = upcoming.min(by: { $0.start < $1.start }) { return event }
        return candidates.filter { $0.end <= now }.max(by: { $0.end < $1.end })
    }

    static func info(from event: EKEvent) -> CalendarEventInfo {
        let attendees = (event.attendees ?? [])
            .filter { $0.participantType != .room && $0.participantType != .resource }
            .compactMap(displayName(of:))
        return CalendarEventInfo(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: event.title ?? "",
            organizer: event.organizer.flatMap(displayName(of:)),
            attendees: attendees,
            conferenceURL: MeetingURLMatcher.conferenceURL(url: event.url, notes: event.notes, location: event.location),
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay
        )
    }

    /// Name when set, else the e-mail address from the `mailto:` URL.
    private static func displayName(of participant: EKParticipant) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let url = participant.url
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = url.absoluteString.dropFirst("mailto:".count)
        return address.isEmpty ? nil : String(address).removingPercentEncoding ?? String(address)
    }
}
