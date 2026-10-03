import Foundation
import Testing
@testable import LapCatSpeakers

@Suite struct SpeakerSelectorsTests {
    private let selectors = SpeakerSelectors(
        participants: [AXNameRule(role: "AXRow", attribute: .description, pattern: #"^(.+?), (?:muted|unmuted)$"#)],
        activeSpeaker: [AXNameRule(attribute: .any, pattern: #"^(.+?) is speaking$"#)],
        selfName: [AXNameRule(attribute: .title, pattern: #"^(.+?) \(me\)$"#)],
        maxDepth: 10
    )

    private func tree(_ children: [AXNodeSnapshot]) -> AXNodeSnapshot {
        AXNodeSnapshot(
            role: "AXWindow", title: "Meeting", children: [AXNodeSnapshot(role: "AXGroup", children: children)])
    }

    @Test func readsNamesFromNestedNodesInOrderWithoutDuplicates() {
        let root = tree([
            AXNodeSnapshot(role: "AXRow", description: "Tom Lee, unmuted"),
            AXNodeSnapshot(role: "AXRow", description: "Priya Shah, muted"),
            AXNodeSnapshot(role: "AXRow", description: "Tom Lee, unmuted"),
            AXNodeSnapshot(role: "AXCell", description: "Alex Kim, muted"),  // wrong role
            AXNodeSnapshot(role: "AXStaticText", value: "Priya Shah is speaking"),
        ])
        let observation = selectors.observation(from: [root])
        #expect(observation.participants == ["Tom Lee", "Priya Shah"])
        #expect(observation.activeNames == ["Priya Shah"])
        #expect(observation.selfName == nil)
    }

    @Test func selfIsNeverActiveAndActiveNamesAreParticipants() {
        let root = tree([
            AXNodeSnapshot(role: "AXStaticText", title: "Mason (me)"),
            AXNodeSnapshot(role: "AXStaticText", description: "Mason is speaking"),
            AXNodeSnapshot(role: "AXStaticText", description: "Dana is speaking"),
        ])
        let observation = selectors.observation(from: [root])
        #expect(observation.selfName == "Mason")
        #expect(observation.activeNames == ["Dana"])
        #expect(observation.participants == ["Dana", "Mason"])
    }

    @Test func invalidPatternIsIgnoredNotFatal() {
        var broken = selectors
        broken.participants.append(AXNameRule(attribute: .any, pattern: "(unclosed"))
        let observation = broken.observation(from: [
            tree([AXNodeSnapshot(role: "AXRow", description: "Tom Lee, muted")])
        ])
        #expect(observation.participants == ["Tom Lee"])
    }

    @Test func jsonOverrideReplacesDefaultsAndBadJSONFallsBack() throws {
        let json = String(decoding: try JSONEncoder().encode(selectors), as: UTF8.self)
        #expect(SpeakerSelectors.decode(json: json, fallback: .zoomDefault) == selectors)
        #expect(SpeakerSelectors.decode(json: "{\"participants\": 3}", fallback: .zoomDefault) == .zoomDefault)
        #expect(SpeakerSelectors.decode(json: nil, fallback: .meetDefault) == .meetDefault)
    }

    @Test func zoomDefaultsReadTheDocumentedRowShape() {
        // Shape assumed by the unverified defaults; update together with them after the axdump spike.
        let root = tree([
            AXNodeSnapshot(role: "AXRow", description: "Mason Goetz, (Host, me), Computer audio unmuted, Video on"),
            AXNodeSnapshot(role: "AXRow", description: "Priya Shah, Computer audio muted, Video off"),
            AXNodeSnapshot(role: "AXGroup", description: "Priya Shah is talking"),
        ])
        let observation = SpeakerSelectors.zoomDefault.observation(from: [root])
        #expect(observation.selfName == "Mason Goetz")
        #expect(observation.participants == ["Mason Goetz", "Priya Shah"])
        #expect(observation.activeNames == ["Priya Shah"])
    }
}
