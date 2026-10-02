import Foundation
import LapCatCore
import Testing
@testable import LapCatSpeech

@Suite struct EchoDeduplicatorTests {
    private let text = "we should ship the onboarding flow before the conference"

    @Test func flagsMicCopyWithinWindow() {
        let mic = [segment(1, .mic, 10_000, 14_000, "We should ship the onboarding flow, before the conference!")]
        let system = [segment(9, .system, 9_800, 13_900, text)]
        #expect(EchoDeduplicator.flag(micSegments: mic, systemSegments: system) == [1])
    }

    @Test func windowBoundaryIsOnePointFiveSeconds() {
        let mic = [segment(1, .mic, 10_000, 14_000, text)]
        // System segment ends exactly 1.5 s before the mic segment starts: still a duplicate.
        #expect(EchoDeduplicator.flag(micSegments: mic, systemSegments: [segment(9, .system, 4_000, 8_500, text)]) == [1])
        #expect(EchoDeduplicator.flag(micSegments: mic, systemSegments: [segment(9, .system, 4_000, 8_499, text)]).isEmpty)
        // System segment starts exactly 1.5 s after the mic segment ends.
        #expect(EchoDeduplicator.flag(micSegments: mic, systemSegments: [segment(9, .system, 15_500, 18_000, text)]) == [1])
        #expect(EchoDeduplicator.flag(micSegments: mic, systemSegments: [segment(9, .system, 15_501, 18_000, text)]).isEmpty)
    }

    @Test func similarityBoundaryIsPointEight() {
        // 10 characters; 2 substitutions → similarity exactly 0.8; 3 → 0.7.
        let mic = [segment(1, .mic, 0, 2_000, "abcdefghij")]
        #expect(EchoDeduplicator.flag(micSegments: mic, systemSegments: [segment(9, .system, 0, 2_000, "abcdefghXY")]) == [1])
        #expect(EchoDeduplicator.flag(micSegments: mic, systemSegments: [segment(9, .system, 0, 2_000, "abcdefgXYZ")]).isEmpty)
    }

    @Test func differentSpeechAtTheSameTimeIsKept() {
        let mic = [segment(1, .mic, 0, 3_000, "sounds good to me")]
        let system = [segment(9, .system, 0, 3_000, text)]
        #expect(EchoDeduplicator.flag(micSegments: mic, systemSegments: system).isEmpty)
    }

    @Test func punctuationOnlyMicSegmentIsNeverFlagged() {
        let mic = [segment(1, .mic, 0, 1_000, "…")]
        let system = [segment(9, .system, 0, 1_000, "!")]
        #expect(EchoDeduplicator.flag(micSegments: mic, systemSegments: system).isEmpty)
    }
}
