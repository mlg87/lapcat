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

    // Tile shapes from the Zoom 7.1.9 recordings (Fixtures/zoom-7.1.9-*.json), with the panel's self row.
    private static let talkingTree = window([
        AXNodeSnapshot(role: "AXStaticText", value: "Mason Goetz (Host, me)"),
        AXNodeSnapshot(role: "AXTabGroup", description: "Tom Lee, Computer audio unmuted, Video off"),
        AXNodeSnapshot(
            role: "AXTabGroup", description: "Priya Shah, Computer audio unmuted, Video off, active speaker"),
    ])

    private static let silentTree = window([
        AXNodeSnapshot(role: "AXStaticText", value: "Mason Goetz (Host, me)"),
        AXNodeSnapshot(role: "AXTabGroup", description: "Tom Lee, Computer audio unmuted, Video off"),
        AXNodeSnapshot(role: "AXTabGroup", description: "Priya Shah, Computer audio unmuted, Video off"),
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
            activeNames: ["Priya Shah"], participants: ["Tom Lee", "Priya Shah", "Mason Goetz"], selfName: "Mason Goetz"
        )
        let silent = SpeakerObservation(
            activeNames: [], participants: ["Tom Lee", "Priya Shah", "Mason Goetz"], selfName: "Mason Goetz")
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
