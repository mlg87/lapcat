import Foundation
import LapCatCore
import LapCatSpeakers
import LapCatSpeech
import Testing

@testable import LapCatAudio
@testable import LapCatSession

/// A prompted Zoom note through `SessionController`: tap scope, meeting row, speaker rows and end,
/// over a fake capture and a scripted speaker source.
@MainActor @Suite struct SessionControllerZoomTests {
    private let sandbox = DefaultsSandbox()
    private let capture = FakeCapture()

    private static let priyaTalking = SpeakerObservation(
        activeNames: ["Priya Shah"], participants: ["Mason", "Priya Shah"], selfName: "Mason")

    private struct Harness {
        var session: SessionController
        var store: Store
        var paths: Paths
        var settings: AppSettings
    }

    private func harness(
        processes: [AudioProcessInfo] = zoomProcesses(),
        speakers: ScriptedSpeakerSource? = ScriptedSpeakerSource([priyaTalking]),
        configure: (AppSettings) -> Void = { _ in }
    ) throws -> Harness {
        let (store, dir) = try makeTempStore()
        let paths = Paths(root: dir)
        let settings = sandbox.settings()
        settings.userDisplayName = "Mason"
        settings.audioTapScope = "app"
        configure(settings)
        let capture = capture
        let session = SessionController(
            store: store, settings: settings, speech: SpeechServices(),
            dependencies: SessionDependencies(
                paths: paths,
                makeCapture: { capture },
                audioProcesses: { processes },
                calendarEvent: { _ in nil },
                speakerSource: { bundleID, _ in
                    guard bundleID == "us.zoom.xos", let speakers else { return nil }
                    return (speakers, .zoomAX)
                }))
        return Harness(session: session, store: store, paths: paths, settings: settings)
    }

    @Test func promptedZoomNoteTapsZoomAndRecordsItsSpeakers() async throws {
        let speakers = ScriptedSpeakerSource([Self.priyaTalking])
        let h = try harness(speakers: speakers)
        let id = try #require(try await h.session.startNewNote(source: zoomSource, startedBy: .prompt))

        let started = try #require(capture.started)
        #expect(started.scope == .app(objectIDs: [1001, 1002], appPID: 500))
        #expect(started.directory == h.paths.audio(meetingID: id))
        #expect(FileManager.default.fileExists(atPath: started.directory.path))
        #expect(h.session.captureScope == started.scope)

        let meeting = try #require(try await h.store.meeting(id: id))
        #expect(meeting.sourceApp == "zoom.us")
        #expect(meeting.sourceBundleID == "us.zoom.xos")
        #expect(meeting.sourcePID == 500)
        #expect(meeting.startedBy == .prompt)
        let me = try await h.store.participants(meetingID: id).filter(\.isMe)
        #expect(me.map(\.displayName) == ["Mason"])

        try #require(await eventually { (try? await h.store.speakerEvents(meetingID: id).count) == 1 })
        #expect(speakers.pids == [500])
        let event = try #require(try await h.store.speakerEvents(meetingID: id).first)
        #expect(event.displayName == "Priya Shah")
        #expect(event.source == .zoomAX)
        #expect(event.tEndMs == nil)
        let others = try await h.store.participants(meetingID: id).filter { !$0.isMe }
        #expect(others.map(\.displayName) == ["Priya Shah"])
        #expect(others.map(\.source) == [.zoomAX])
    }

    @Test func systemTapSettingRecordsEverythingButLapCat() async throws {
        let h = try harness { $0.audioTapScope = "system" }
        try await h.session.startNewNote(source: zoomSource, startedBy: .prompt)
        #expect(capture.started?.scope == .systemExcludingSelf)
    }

    @Test func zoomMissingFromCoreAudioFallsBackToTheSystemTap() async throws {
        let h = try harness(processes: [])
        try await h.session.startNewNote(source: zoomSource, startedBy: .prompt)
        #expect(capture.started?.scope == .systemExcludingSelf)
    }

    @Test func endClosesSpeakerEventsAndHandsTheMeetingOn() async throws {
        let h = try harness()
        let ended = Box<[String]>([])
        h.session.onEnded = { ended.value.append($0) }
        let id = try #require(try await h.session.startNewNote(source: zoomSource, startedBy: .prompt))
        try #require(await eventually { (try? await h.store.speakerEvents(meetingID: id).count) == 1 })

        await h.session.end()
        let event = try #require(try await h.store.speakerEvents(meetingID: id).first)
        #expect(event.tEndMs != nil)
        #expect(h.session.captureScope == nil)
        #expect(h.session.state == .idle)
        let meeting = try #require(try await h.store.meeting(id: id))
        #expect(meeting.endedAt != nil)
        #expect(meeting.status == .processing)
        #expect(ended.value == [id])
        #expect(capture.stopCount == 1)
    }

    @Test func noSpeakerRowsWithoutAnAdapter() async throws {
        let h = try harness(speakers: nil)
        let id = try #require(try await h.session.startNewNote(source: zoomSource, startedBy: .prompt))
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await h.store.speakerEvents(meetingID: id).isEmpty)
        #expect(try await h.store.participants(meetingID: id).allSatisfy(\.isMe))
    }
}

@MainActor final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
