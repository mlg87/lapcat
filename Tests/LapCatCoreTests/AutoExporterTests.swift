import Foundation
import Testing
@testable import LapCatCore

struct AutoExporterTests {
    @Test func writesBundleRecordsPathAndOverwritesOnReexport() async throws {
        let (store, dir) = try makeTempStore()
        let folder = dir.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meeting = try await store.createMeeting(
            title: "Sync", startedBy: .manual, now: Date(timeIntervalSince1970: 1_790_000_000))

        let first = try #require(
            try await AutoExporter.export(meetingID: meeting.id, folder: folder, store: store, timeZone: utc))
        #expect(first.lastPathComponent == "2026-09-21 Sync.md")
        #expect(try await store.meeting(id: meeting.id)?.exportPath == first.path)

        meeting = try #require(try await store.meeting(id: meeting.id))
        meeting.title = "Renamed"
        try await store.updateMeeting(meeting)
        let second = try #require(
            try await AutoExporter.export(meetingID: meeting.id, folder: folder, store: store, timeZone: utc))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files == ["2026-09-21 Renamed.md"])
        #expect(try String(contentsOf: second, encoding: .utf8).contains("title: \"Renamed\""))

        // Another meeting with the same date and title does not overwrite the first one's file.
        let twin = try await store.createMeeting(
            title: "Renamed", startedBy: .manual, now: Date(timeIntervalSince1970: 1_790_000_100))
        let third = try #require(
            try await AutoExporter.export(meetingID: twin.id, folder: folder, store: store, timeZone: utc))
        #expect(third.lastPathComponent == "2026-09-21 Renamed 2.md")
    }

    @Test func missingFolderIsSkippedWithoutError() async throws {
        let (store, dir) = try makeTempStore()
        let meeting = try await store.createMeeting(title: "Sync", startedBy: .manual)
        let result = try await AutoExporter.export(
            meetingID: meeting.id, folder: dir.appendingPathComponent("nope"), store: store)
        #expect(result == nil)
        #expect(try await store.meeting(id: meeting.id)?.exportPath == nil)
    }
}
