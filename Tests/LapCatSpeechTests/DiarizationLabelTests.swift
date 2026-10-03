import Testing

@testable import LapCatSpeech

@Suite struct DiarizationLabelTests {
    @Test func labelsSpeakersByFirstAppearanceInTime() {
        // Engine emits out of order with opaque ids; the earliest speaker becomes Speaker 1.
        let raw = [
            RawSpeakerTurn(startSeconds: 12.0, endSeconds: 15.5, speakerID: "S0"),
            RawSpeakerTurn(startSeconds: 0.5, endSeconds: 6.25, speakerID: "S3"),
            RawSpeakerTurn(startSeconds: 6.5, endSeconds: 11.0, speakerID: "S0"),
            RawSpeakerTurn(startSeconds: 16.0, endSeconds: 20.0, speakerID: "S7"),
            RawSpeakerTurn(startSeconds: 20.0, endSeconds: 20.0, speakerID: "S9"),  // zero length: dropped
        ]
        #expect(
            DiarizationLabels.normalize(raw) == [
                DiarizedTurn(startMs: 500, endMs: 6_250, cluster: "Speaker 1"),
                DiarizedTurn(startMs: 6_500, endMs: 11_000, cluster: "Speaker 2"),
                DiarizedTurn(startMs: 12_000, endMs: 15_500, cluster: "Speaker 2"),
                DiarizedTurn(startMs: 16_000, endMs: 20_000, cluster: "Speaker 3"),
            ])
    }
}
