import Foundation
import Testing

@testable import LapCatCore

@Suite struct MeetingListFilterTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func composesEveryFilterWithSearch() {
        let filter = MeetingListFilter(folderID: "f1", starredOnly: true, dateScope: .today, personName: "  Priya ")
        let result = filter.meetingFilter(search: " pricing ", now: date("2026-10-02T15:30:00Z"), calendar: calendar)
        #expect(result.search == "pricing")
        #expect(result.folderID == "f1")
        #expect(result.starredOnly)
        #expect(result.personName == "Priya")
        #expect(result.dateRange == date("2026-10-02T00:00:00Z")...date("2026-10-02T23:59:59Z"))
    }

    @Test func shortSearchAndBlankPersonAreIgnored() {
        let result = MeetingListFilter(personName: "   ").meetingFilter(search: "p", now: Date(), calendar: calendar)
        #expect(result == MeetingFilter())
        #expect(!MeetingListFilter(personName: "   ").isActive)
    }

    @Test func lastSevenDaysIncludesTodayAndSixPriorDays() {
        let range = MeetingListFilter(dateScope: .last7Days).dateRange(
            now: date("2026-10-02T09:00:00Z"), calendar: calendar)
        #expect(range == date("2026-09-26T00:00:00Z")...date("2026-10-02T23:59:59Z"))
    }

    @Test func customRangeCoversWholeDaysInEitherOrder() {
        let filter = MeetingListFilter(
            dateScope: .custom, customStart: date("2026-09-30T18:00:00Z"), customEnd: date("2026-09-28T06:00:00Z"))
        #expect(filter.dateRange(calendar: calendar) == date("2026-09-28T00:00:00Z")...date("2026-09-30T23:59:59Z"))
    }

    @Test func storeHonoursComposedFolderAndStarFilters() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try await store.createFolder(name: "Clients")
        let filed = try await store.createMeeting(
            title: "Filed", startedBy: .manual, sourceApp: "zoom", bundleID: nil, pid: nil)
        let starred = try await store.createMeeting(
            title: "Starred", startedBy: .manual, sourceApp: "zoom", bundleID: nil, pid: nil)
        try await store.setFolder(meetingID: filed.id, folderID: folder.id)
        try await store.setStarred(meetingID: starred.id, starred: true)

        let inFolder = try await store.meetings(
            filter: MeetingListFilter(folderID: folder.id).meetingFilter(search: ""))
        #expect(inFolder.map(\.id) == [filed.id])
        let onlyStarred = try await store.meetings(
            filter: MeetingListFilter(starredOnly: true).meetingFilter(search: ""))
        #expect(onlyStarred.map(\.id) == [starred.id])

        try await store.deleteFolder(id: folder.id)
        #expect(try await store.meeting(id: filed.id)?.folderID == nil)
    }
}

@Suite struct TagListTests {
    @Test func parsesCommaSeparatedNamesDroppingBlanksAndDuplicates() {
        #expect(TagList.parse(" sales, ,Q4 ,sales,  SALES , renewal") == ["sales", "Q4", "renewal"])
        #expect(TagList.parse("  ") == [])
    }
}
