import Foundation
import LapCatCore
import LapCatSpeakers
import Testing
import os

@testable import LapCatSession

/// Zoom observations → `speaker_event` and `participant` rows (plan §8.4).
@Suite struct SpeakerEventRecorderTests {
    private static let talking = SpeakerObservation(
        activeNames: ["Priya Shah"], participants: ["Mason Goetz", "Priya Shah"], selfName: "Mason Goetz")
    private static let silent = SpeakerObservation(
        activeNames: [], participants: ["Mason Goetz", "Priya Shah"], selfName: "Mason Goetz")

    /// Session-clock readings handed out in order, one per `elapsedMs` call.
    private static func clock(_ readings: [Int]) -> @Sendable () async -> Int {
        let remaining = OSAllocatedUnfairLock(initialState: readings)
        return { remaining.withLock { $0.isEmpty ? -1 : $0.removeFirst() } }
    }

    private func meeting(_ store: Store) async throws -> String {
        try await store.createMeeting(title: "Zoom call", startedBy: .prompt, sourceApp: "zoom.us").id
    }

    @Test func eachSpeakingStretchBecomesOneEventAndSelfIsNoParticipant() async throws {
        let (store, _) = try makeTempStore()
        let id = try await meeting(store)
        let recorder = SpeakerEventRecorder(
            store: store, meetingID: id, source: .zoomAX, elapsedMs: Self.clock([0, 250, 500, 750, 1000]))
        await recorder.start(
            adapter: ScriptedSpeakerSource([Self.talking, Self.talking, Self.silent, Self.talking]), pid: 500)
        try #require(await eventually { (try? await store.speakerEvents(meetingID: id).count) == 2 })
        await recorder.stop()

        let rows = try await store.speakerEvents(meetingID: id).map { ($0.displayName, $0.tStartMs, $0.tEndMs) }
        #expect(rows.count == 2)
        #expect(rows.map(\.0) == ["Priya Shah", "Priya Shah"])
        #expect(rows.map(\.1) == [0, 750])
        #expect(rows.map(\.2) == [500, 1000])
        #expect(try await store.speakerEvents(meetingID: id).allSatisfy { $0.source == .zoomAX })
        let participants = try await store.participants(meetingID: id)
        #expect(participants.map(\.displayName) == ["Priya Shah"])
        #expect(participants.map(\.source) == [.zoomAX])
    }

    @Test func theUserSpeakingOpensNoEvent() async throws {
        let (store, _) = try makeTempStore()
        let id = try await meeting(store)
        let me = SpeakerObservation(
            activeNames: ["Mason Goetz"], participants: ["Mason Goetz"], selfName: "Mason Goetz")
        let recorder = SpeakerEventRecorder(
            store: store, meetingID: id, source: .zoomAX, elapsedMs: Self.clock([0, 100, 200]))
        await recorder.start(adapter: ScriptedSpeakerSource([me, me]), pid: 500)
        try await Task.sleep(for: .milliseconds(200))
        await recorder.stop()
        #expect(try await store.speakerEvents(meetingID: id).isEmpty)
        #expect(try await store.participants(meetingID: id).isEmpty)
    }
}

@Suite struct PostMeetingPipelineTests {
    @Test func zoomBundlesNameSegmentsAsZoomAndEverythingElseAsMeet() {
        #expect(PostMeetingPipeline.namedSource(forBundleID: "us.zoom.xos") == .zoomAX)
        #expect(PostMeetingPipeline.namedSource(forBundleID: "US.Zoom.xos") == .zoomAX)
        #expect(PostMeetingPipeline.namedSource(forBundleID: "com.google.Chrome") == .meetAX)
        #expect(PostMeetingPipeline.namedSource(forBundleID: nil) == .meetAX)
    }
}
