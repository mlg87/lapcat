import Foundation
import Testing

@testable import LapCatCore

struct RecallSearchTests {
    @Test func anyOfSearchMatchesAnyKeywordAndFiltersByKindFolderAndDate() async throws {
        let (store, _) = try makeTempStore()
        let folder = try await store.createFolder(name: "Sales")
        let a = try await store.createMeeting(title: "A", startedBy: .manual, now: Date(timeIntervalSince1970: 1_000))
        let b = try await store.createMeeting(title: "B", startedBy: .manual, now: Date(timeIntervalSince1970: 5_000))
        try await store.setFolder(meetingID: a.id, folderID: folder.id)
        try await store.appendSegments([
            Segment(
                meetingID: a.id, channel: .system, tStartMs: 0, tEndMs: 1, text: "Priya will send the pricing deck",
                pass: .final),
            Segment(
                meetingID: b.id, channel: .system, tStartMs: 0, tEndMs: 1, text: "Pricing stays flat", pass: .final),
        ])
        try await store.reindexFTS(meetingID: a.id)
        try await store.reindexFTS(meetingID: b.id)

        // A question whose words are not all present still finds both meetings.
        let all = try await store.search(anyOf: "What did Priya say about pricing?", kinds: [.segment])
        #expect(Set(all.map(\.meetingID)) == [a.id, b.id])
        #expect(
            try await store.search(anyOf: "pricing", kinds: [.segment], folderID: folder.id).map(\.meetingID) == [a.id])
        let late = Date(timeIntervalSince1970: 4_000)...Date(timeIntervalSince1970: 6_000)
        #expect(try await store.search(anyOf: "pricing", kinds: [.segment], dateRange: late).map(\.meetingID) == [b.id])
        #expect(try await store.search(anyOf: "pricing", kinds: [.raw]).isEmpty)
        #expect(try await store.search(anyOf: "what is the", kinds: [.segment]).isEmpty)
    }
}
