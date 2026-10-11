import Foundation
import Testing

@testable import LapCatSpeakers

/// `SpeakerSelectors.zoomDefault` against accessibility trees recorded from Zoom 7.1.9 during a live
/// call (#61). Names are replaced: "Alex Rivera" is the host running LapCat (participants panel open),
/// "Priya Shah" and "Tom Lee" are the other people.
@Suite struct ZoomFixtureTests {
    private static func trees(_ name: String) throws -> [AXNodeSnapshot] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([AXNodeSnapshot].self, from: Data(contentsOf: url))
    }

    @Test func threePersonCallNamesTheActiveSpeaker() throws {
        let priya = SpeakerSelectors.zoomDefault.observation(
            from: try Self.trees("zoom-7.1.9-three-person-priya-talking"))
        #expect(priya.activeNames == ["Priya Shah"])
        #expect(Set(priya.participants) == ["Alex Rivera", "Priya Shah", "Tom Lee"])
        #expect(priya.selfName == "Alex Rivera")

        let tom = SpeakerSelectors.zoomDefault.observation(from: try Self.trees("zoom-7.1.9-three-person-tom-talking"))
        #expect(tom.activeNames == ["Tom Lee"])
    }

    @Test func noActiveSpeakerLabelMeansNobodyIsActive() throws {
        let observation = SpeakerSelectors.zoomDefault.observation(
            from: try Self.trees("zoom-7.1.9-three-person-no-speaker"))
        #expect(observation.activeNames.isEmpty)
        #expect(Set(observation.participants) == ["Alex Rivera", "Priya Shah", "Tom Lee"])
    }

    /// Zoom labels no active speaker in a call of two: only the participants are readable.
    @Test func twoPersonCallHasParticipantsButNoActiveSpeaker() throws {
        let observation = SpeakerSelectors.zoomDefault.observation(from: try Self.trees("zoom-7.1.9-two-person"))
        #expect(observation.activeNames.isEmpty)
        #expect(Set(observation.participants) == ["Alex Rivera", "Tom Lee"])
        #expect(observation.selfName == "Alex Rivera")
    }

    @Test func panelPronounsDoNotCreateASecondParticipant() throws {
        let observation = SpeakerSelectors.zoomDefault.observation(
            from: try Self.trees("zoom-7.1.9-three-person-priya-talking"))
        #expect(!observation.participants.contains { $0.contains("(") })
    }

    @Test func overrideWithoutTheActiveSpeakerRuleReadsNoSpeaker() throws {
        var selectors = SpeakerSelectors.zoomDefault
        selectors.activeSpeaker = [AXNameRule(attribute: .any, pattern: "^never$")]
        let json = String(decoding: try JSONEncoder().encode(selectors), as: UTF8.self)
        let decoded = SpeakerSelectors.decode(json: json, fallback: .zoomDefault)
        #expect(decoded.observation(from: try Self.trees("zoom-7.1.9-three-person-priya-talking")).activeNames.isEmpty)
    }
}
