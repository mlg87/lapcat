import Foundation
import Testing
@testable import LapCatCore

struct RetentionSweeperTests {
    @Test func sweepDeletesOnlyExpiredMeetingsAudio() async throws {
        let (store, dir) = try makeTempStore()
        let paths = Paths(root: dir)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fm = FileManager.default

        func meeting(retainedUntil: Date?) async throws -> Meeting {
            var m = try await store.createMeeting(title: "M", startedBy: .manual)
            m.audioRetainedUntil = retainedUntil
            try await store.updateMeeting(m)
            let audioDir = paths.audio(meetingID: m.id)
            try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
            for channel in Channel.allCases {
                let file = audioDir.appendingPathComponent(channel == .mic ? "mic.aac" : "them.aac")
                try Data([1, 2, 3]).write(to: file)
                try await store.saveAudioFile(AudioFile(meetingID: m.id, channel: channel, path: file.path))
            }
            return m
        }
        let expired = try await meeting(retainedUntil: now.addingTimeInterval(-86_400))
        let dueNow = try await meeting(retainedUntil: now)
        let future = try await meeting(retainedUntil: now.addingTimeInterval(60))
        let forever = try await meeting(retainedUntil: nil)

        let swept = try await RetentionSweeper(store: store, paths: paths).sweep(now: now)
        #expect(Set(swept) == [expired.id, dueNow.id])
        for gone in [expired, dueNow] {
            #expect(!fm.fileExists(atPath: paths.audio(meetingID: gone.id).path))
            #expect(try await store.audioFiles(meetingID: gone.id).isEmpty)
            #expect(try await store.meeting(id: gone.id)?.audioRetainedUntil == nil)
        }
        for kept in [future, forever] {
            #expect(fm.fileExists(atPath: paths.audio(meetingID: kept.id).appendingPathComponent("them.aac").path))
            #expect(try await store.audioFiles(meetingID: kept.id).count == 2)
        }
        #expect(try await store.meeting(id: future.id)?.audioRetainedUntil == now.addingTimeInterval(60))
        #expect(try await RetentionSweeper(store: store, paths: paths).sweep(now: now).isEmpty)
    }
}
