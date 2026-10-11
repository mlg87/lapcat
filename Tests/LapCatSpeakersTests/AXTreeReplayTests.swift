import Foundation
import Testing
import os

@testable import LapCatSpeakers

/// `ZoomAXAdapter` over scripted trees: the poll loop, selector application and cancellation that
/// the live recorder relies on, without Accessibility (#60).
@Suite struct AXTreeReplayTests {
    private static func window(_ children: [AXNodeSnapshot]) -> AXNodeSnapshot {
        AXNodeSnapshot(role: "AXWindow", title: "Zoom Meeting", children: children)
    }

    private static let talkingTree = window([
        AXNodeSnapshot(role: "AXRow", description: "Mason Goetz, (Host, me), Computer audio unmuted, Video on"),
        AXNodeSnapshot(role: "AXRow", description: "Priya Shah, Computer audio unmuted, Video off"),
        AXNodeSnapshot(role: "AXGroup", description: "Priya Shah is talking"),
    ])

    private static let silentTree = window([
        AXNodeSnapshot(role: "AXRow", description: "Mason Goetz, (Host, me), Computer audio unmuted, Video on"),
        AXNodeSnapshot(role: "AXRow", description: "Priya Shah, Computer audio muted, Video off"),
    ])

    /// Pops one scripted tree per poll (then empty trees) and counts the polls.
    private final class ScriptedTrees: Sendable {
        private let state: OSAllocatedUnfairLock<(trees: [[AXNodeSnapshot]], calls: Int)>

        init(_ trees: [[AXNodeSnapshot]]) { state = OSAllocatedUnfairLock(initialState: (trees, 0)) }

        var calls: Int { state.withLock { $0.calls } }

        func next(pid: pid_t, selectors: SpeakerSelectors) -> [AXNodeSnapshot] {
            state.withLock { state in
                state.calls += 1
                return state.trees.isEmpty ? [] : state.trees.removeFirst()
            }
        }
    }

    @Test func pollsTheProviderAndAppliesTheZoomSelectors() async {
        let scripted = ScriptedTrees([[Self.talkingTree], [Self.silentTree], []])
        let adapter = ZoomAXAdapter(selectors: .zoomDefault, trees: scripted.next)
        var observations: [SpeakerObservation] = []
        for await observation in adapter.observe(pid: 1, interval: 0.01) {
            observations.append(observation)
            if observations.count == 3 { break }
        }
        let talking = SpeakerObservation(
            activeNames: ["Priya Shah"], participants: ["Mason Goetz", "Priya Shah"], selfName: "Mason Goetz")
        let silent = SpeakerObservation(
            activeNames: [], participants: ["Mason Goetz", "Priya Shah"], selfName: "Mason Goetz")
        #expect(observations == [talking, silent, .empty])
    }

    @Test func leavingTheStreamStopsPolling() async throws {
        let scripted = ScriptedTrees([])
        let adapter = ZoomAXAdapter(selectors: .zoomDefault, trees: scripted.next)
        var received = 0
        for await _ in adapter.observe(pid: 1, interval: 0.01) {
            received += 1
            if received == 2 { break }
        }
        // One poll may already be in flight when the consumer leaves.
        try await Task.sleep(for: .milliseconds(100))
        let settled = scripted.calls
        try await Task.sleep(for: .milliseconds(100))
        #expect(scripted.calls == settled)
    }
}
