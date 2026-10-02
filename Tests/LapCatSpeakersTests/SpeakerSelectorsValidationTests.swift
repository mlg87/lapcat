import Foundation
import Testing
@testable import LapCatSpeakers

@Suite struct SpeakerSelectorsValidationTests {
    @Test func compiledDefaultsRoundTripThroughTheEditorText() throws {
        for selectors in [SpeakerSelectors.zoomDefault, .meetDefault] {
            #expect(try SpeakerSelectors.validate(json: selectors.prettyJSON) == selectors)
        }
    }

    @Test func malformedJSONIsRejected() {
        #expect(throws: SpeakerSelectorsValidationError.self) { try SpeakerSelectors.validate(json: "{ \"maxDepth\": ") }
    }

    @Test func missingKeyNamesTheKey() {
        let json = #"{"participants": [], "activeSpeaker": [], "maxDepth": 5}"#
        #expect(throws: SpeakerSelectorsValidationError.invalidJSON("missing key “selfName”")) {
            try SpeakerSelectors.validate(json: json)
        }
    }

    @Test func uncompilableRegexIsRejectedEvenThoughItDecodes() {
        var selectors = SpeakerSelectors.zoomDefault
        selectors.activeSpeaker = [AXNameRule(attribute: .any, pattern: "(unclosed")]
        #expect(throws: SpeakerSelectorsValidationError.invalidPattern(field: "activeSpeaker", pattern: "(unclosed")) {
            try SpeakerSelectors.validate(json: selectors.prettyJSON)
        }
    }

    @Test func nonPositiveDepthIsRejected() {
        var selectors = SpeakerSelectors.meetDefault
        selectors.maxDepth = 0
        #expect(throws: SpeakerSelectorsValidationError.invalidMaxDepth(0)) {
            try SpeakerSelectors.validate(json: selectors.prettyJSON)
        }
    }
}
