import Foundation
import LapCatCore
import LapCatSpeakers
import os

/// Records who the meeting app shows as speaking (plan §8.4): one `speaker_event` row per
/// continuous stretch a name is active, timed on the session clock, plus platform participants.
public actor SpeakerEventRecorder {
    private let store: Store
    private let meetingID: String
    private let source: SpeakerEventSource
    private let elapsedMs: @Sendable () async -> Int
    private var open: [String: Int64] = [:]
    private var knownParticipants: Set<String> = []
    private var selfName: String?
    private var task: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "SpeakerEventRecorder")

    public init(
        store: Store, meetingID: String, source: SpeakerEventSource, elapsedMs: @escaping @Sendable () async -> Int
    ) {
        self.store = store
        self.meetingID = meetingID
        self.source = source
        self.elapsedMs = elapsedMs
    }

    public func start(adapter: any SpeakerSource, pid: pid_t) {
        let observations = adapter.observe(pid: pid, interval: 0.25)
        task = Task {
            for await observation in observations {
                await self.apply(observation)
            }
        }
    }

    /// Stops observing and closes every open event at the current session time.
    public func stop() async {
        task?.cancel()
        task = nil
        let now = await elapsedMs()
        for id in open.values { try? await store.closeSpeakerEvent(id: id, tEndMs: now) }
        open.removeAll()
    }

    private func apply(_ observation: SpeakerObservation) async {
        let now = await elapsedMs()
        if let name = observation.selfName { selfName = name }
        // The user's own tile lighting up is the mic channel's speech, never a "Them" speaker.
        let active = Set(observation.activeNames).subtracting(selfName.map { [$0] } ?? [])
        do {
            for name in active where open[name] == nil {
                let event = try await store.appendSpeakerEvent(
                    meetingID: meetingID, displayName: name, source: source, tStartMs: now)
                open[name] = event.id
            }
            for (name, id) in open where !active.contains(name) {
                try await store.closeSpeakerEvent(id: id, tEndMs: now)
                open[name] = nil
            }
            let participantSource: ParticipantSource = source == .zoomAX ? .zoomAX : .meetAX
            for name in observation.participants where !knownParticipants.contains(name) && name != selfName {
                knownParticipants.insert(name)
                try await store.upsertParticipant(meetingID: meetingID, name: name, source: participantSource)
            }
        } catch {
            Self.logger.error("speaker event write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
