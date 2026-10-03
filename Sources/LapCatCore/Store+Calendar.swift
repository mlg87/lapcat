import Foundation
import GRDB

extension Store {
    /// Links a meeting to its calendar event at session start (Step 9.1), in one transaction:
    /// writes `calendar_snapshot` (replacing any previous one), adds every attendee and the
    /// organizer as `participant(source: calendar)` (existing names are kept as they are),
    /// sets `meeting.calendar_event_id` and, when the event has a non-empty title, the meeting title.
    @discardableResult
    public func applyCalendarEvent(_ event: CalendarEventInfo, toMeeting meetingID: String, now: Date = Date())
        async throws -> Meeting
    {
        try await pool.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingID) else {
                throw StoreError.notFound("meeting \(meetingID)")
            }
            let snapshot = CalendarSnapshot(
                meetingID: meetingID,
                eventTitle: event.title,
                organizer: event.organizer,
                attendees: event.attendees,
                conferenceURL: event.conferenceURL?.absoluteString,
                scheduledStart: event.start,
                scheduledEnd: event.end)
            try snapshot.insert(db, onConflict: .replace)

            var seen = Set<String>()
            for name in event.attendees + [event.organizer].compactMap({ $0 }) {
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO participant(meeting_id, display_name, source) VALUES (?, ?, ?)
                        ON CONFLICT(meeting_id, display_name) DO NOTHING
                        """,
                    arguments: [meetingID, name, ParticipantSource.calendar.rawValue])
            }

            meeting.calendarEventID = event.id
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { meeting.title = title }
            meeting.updatedAt = now
            try meeting.update(db)
            return meeting
        }
    }
}
