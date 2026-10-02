import Foundation
import Testing
@testable import LapCatCore

struct CalendarSelectionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = CalendarService.defaultWindow

    func event(_ id: String, start: TimeInterval, minutes: TimeInterval = 30, allDay: Bool = false) -> CalendarEventInfo {
        CalendarEventInfo(
            id: id, title: id, start: now.addingTimeInterval(start),
            end: now.addingTimeInterval(start + minutes * 60), isAllDay: allDay)
    }

    @Test func inProgressBeatsUpcomingEvenWhenUpcomingIsCloser() {
        let events = [event("next", start: 60), event("running", start: -20 * 60, minutes: 60)]
        #expect(CalendarService.select(from: events, now: now, window: window)?.id == "running")
    }

    @Test func overlappingInProgressPicksMostRecentlyStarted() {
        let events = [event("long", start: -40 * 60, minutes: 120), event("backToBack", start: -2 * 60)]
        #expect(CalendarService.select(from: events, now: now, window: window)?.id == "backToBack")
    }

    @Test func upcomingPicksSoonestStart() {
        let events = [event("later", start: 14 * 60), event("sooner", start: 5 * 60)]
        #expect(CalendarService.select(from: events, now: now, window: window)?.id == "sooner")
    }

    @Test func eventsOutsideWindowAreIgnored() {
        let events = [
            event("tooLate", start: 16 * 60),
            event("endedLongAgo", start: -60 * 60, minutes: 30),  // ended 30 min ago
        ]
        #expect(CalendarService.select(from: events, now: now, window: window) == nil)
    }

    @Test func recentlyEndedIsLastResortAndAllDayNeverCounts() {
        let ended = event("overran", start: -40 * 60, minutes: 30)  // ended 10 min ago
        let allDay = event("holiday", start: -3_600, minutes: 24 * 60, allDay: true)
        #expect(CalendarService.select(from: [ended, allDay], now: now, window: window)?.id == "overran")
        #expect(CalendarService.select(from: [allDay], now: now, window: window) == nil)
        #expect(CalendarService.select(from: [ended, event("soon", start: 600)], now: now, window: window)?.id == "soon")
    }

    @Test func startingWithinTheNextMinuteWindow() {
        let window: ClosedRange<TimeInterval> = 0...60
        #expect(CalendarService.select(from: [event("in2min", start: 120)], now: now, window: window) == nil)
        #expect(CalendarService.select(from: [event("in1min", start: 60)], now: now, window: window)?.id == "in1min")
    }
}

struct MeetingURLMatcherTests {
    @Test func eventURLWinsWhenItIsAMeetingLink() {
        let url = MeetingURLMatcher.conferenceURL(
            url: URL(string: "https://meet.google.com/abc-defg-hij"),
            notes: "Join https://acme.zoom.us/j/123456789", location: nil)
        #expect(url?.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test func nonMeetingEventURLFallsThroughToNotesThenLocation() {
        let notes = """
            Agenda: https://docs.google.com/doc/1
            ──────────
            Join Zoom Meeting <https://us02web.zoom.us/j/87654321098?pwd=AbC123.1>
            Meeting ID: 876 5432 1098
            """
        let fromNotes = MeetingURLMatcher.conferenceURL(
            url: URL(string: "https://example.com/agenda"), notes: notes, location: "https://meet.google.com/xyz-abcd-efg")
        #expect(fromNotes?.absoluteString == "https://us02web.zoom.us/j/87654321098?pwd=AbC123.1")

        let fromLocation = MeetingURLMatcher.conferenceURL(
            url: nil, notes: "no link here", location: "Room 4 / https://meet.google.com/xyz-abcd-efg")
        #expect(fromLocation?.absoluteString == "https://meet.google.com/xyz-abcd-efg")
    }

    @Test func firstLinkInTextWinsAcrossPlatforms() {
        let text = "Backup: https://meet.google.com/aaa-bbbb-ccc primary https://zoom.us/j/111"
        #expect(MeetingURLMatcher.firstMeetingURL(in: text)?.absoluteString == "https://meet.google.com/aaa-bbbb-ccc")
    }

    @Test func nonJoinLinksDoNotMatch() {
        for text in [
            "https://zoom.us/meeting/schedule", "https://zoom.us/j/", "https://meet.google.com/landing",
            "https://meet.google.com/abc-defg-hijk", "http://meet.google.com/abc-defg-hij", "https://notzoom.us.evil.com/j/1",
        ] {
            #expect(MeetingURLMatcher.firstMeetingURL(in: text) == nil, "\(text)")
        }
        #expect(MeetingURLMatcher.conferenceURL(url: nil, notes: nil, location: nil) == nil)
    }

    @Test func platformDetection() {
        #expect(MeetingURLMatcher.platform(of: URL(string: "https://acme.zoom.us/j/123?pwd=x")!) == .zoom)
        #expect(MeetingURLMatcher.platform(of: URL(string: "https://meet.google.com/abc-defg-hij")!) == .meet)
        #expect(MeetingURLMatcher.platform(of: URL(string: "https://example.com/?u=https://zoom.us/j/1")!) == nil)
    }

    @Test func meetTabRegexAcceptsCallTabsOnly() {
        #expect(MeetingURLMatcher.meetCode(inTab: URL(string: "https://meet.google.com/abc-defg-hij")!) == "abc-defg-hij")
        #expect(MeetingURLMatcher.meetCode(inTab: URL(string: "https://meet.google.com/abc-defg-hij?authuser=1")!) == "abc-defg-hij")
        #expect(MeetingURLMatcher.isMeetCallTab(URL(string: "https://meet.google.com/abc-defg-hij/")!))
        for tab in [
            "https://meet.google.com/", "https://meet.google.com/landing", "https://meet.google.com/new",
            "https://meet.google.com/abc-defg-hijk", "https://meet.google.com/ABC-DEFG-HIJ",
            "https://www.google.com/search?q=meet.google.com/abc-defg-hij",
        ] {
            #expect(!MeetingURLMatcher.isMeetCallTab(URL(string: tab)!), "\(tab)")
        }
    }

    @Test func browserScriptsCoverChromiumAndSafariButNotFirefox() {
        #expect(BrowserTabProbe.script(for: "company.thebrowser.Browser")?.contains("active tab of front window") == true)
        #expect(BrowserTabProbe.script(for: "com.apple.Safari")?.contains("current tab of front window") == true)
        #expect(BrowserTabProbe.script(for: "org.mozilla.firefox") == nil)
    }
}

struct StoreCalendarTests {
    @Test func applyingAnEventWritesSnapshotParticipantsAndTitleWithoutDuplicates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lapcat-tests-\(UUID().uuidString)")
        let store = try Store(databaseURL: dir.appendingPathComponent("lapcat.sqlite"))
        let meeting = try await store.createMeeting(title: "Note 2026-10-01 10:00", startedBy: .prompt)
        _ = try await store.upsertParticipant(meetingID: meeting.id, name: "Priya Shah", source: .zoomAX)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CalendarEventInfo(
            id: "evt-1", title: "Pricing review", organizer: "Dana Lee",
            attendees: ["Priya Shah", "Dana Lee", "Sam Ortiz"],
            conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            start: start, end: start.addingTimeInterval(1_800))

        let updated = try await store.applyCalendarEvent(event, toMeeting: meeting.id)
        try await store.applyCalendarEvent(event, toMeeting: meeting.id)  // idempotent

        #expect(updated.title == "Pricing review")
        #expect(updated.calendarEventID == "evt-1")
        let snapshot = try #require(try await store.calendarSnapshot(meetingID: meeting.id))
        #expect(snapshot.attendees == ["Priya Shah", "Dana Lee", "Sam Ortiz"])
        #expect(snapshot.organizer == "Dana Lee")
        #expect(snapshot.conferenceURL == "https://meet.google.com/abc-defg-hij")
        #expect(snapshot.scheduledEnd == start.addingTimeInterval(1_800))

        let participants = try await store.participants(meetingID: meeting.id)
        #expect(participants.map(\.displayName) == ["Priya Shah", "Dana Lee", "Sam Ortiz"])
        // An existing platform-sourced participant keeps its source.
        #expect(participants.first?.source == .zoomAX)
        #expect(participants.dropFirst().allSatisfy { $0.source == .calendar })

        await #expect(throws: StoreError.notFound("meeting missing")) {
            try await store.applyCalendarEvent(event, toMeeting: "missing")
        }
    }
}
