import Foundation
import Testing
import LapCatSpeech

@Suite struct EngineSelectorTests {
    private func config(_ engine: SpeechConfig.EngineChoice) -> SpeechConfig {
        SpeechConfig(
            engine: engine,
            whisperLiveModel: "ggml-small.en.bin",
            whisperFinalModel: "ggml-large-v3-turbo-q5_0.bin",
            parakeetVersion: "v2",
            modelsDirectory: URL(fileURLWithPath: "/tmp/models")
        )
    }

    @Test func autoUsesParakeetForBothPassesOnArm64() {
        let selector = EngineSelector(config: config(.auto), architecture: .arm64)
        #expect(selector.liveEngine() == .parakeet(version: "v2"))
        #expect(selector.finalEngine() == .parakeet(version: "v2"))
    }

    @Test func autoUsesWhisperLiveAndFinalModelsOnIntel() {
        let selector = EngineSelector(config: config(.auto), architecture: .x86_64)
        #expect(selector.liveEngine() == .whisper(modelFile: "ggml-small.en.bin"))
        #expect(selector.finalEngine() == .whisper(modelFile: "ggml-large-v3-turbo-q5_0.bin"))
    }

    @Test(arguments: [CPUArchitecture.arm64, .x86_64])
    func explicitChoiceOverridesArchitectureForBothPasses(architecture: CPUArchitecture) {
        let whisper = EngineSelector(config: config(.whisper), architecture: architecture)
        #expect(whisper.liveEngine() == .whisper(modelFile: "ggml-small.en.bin"))
        #expect(whisper.finalEngine() == .whisper(modelFile: "ggml-large-v3-turbo-q5_0.bin"))
        let parakeet = EngineSelector(config: config(.parakeet), architecture: architecture)
        #expect(parakeet.liveEngine() == .parakeet(version: "v2"))
        #expect(parakeet.finalEngine() == .parakeet(version: "v2"))
    }

    @Test func servicesCacheOneEnginePerIDWithMatchingIDs() async {
        let services = SpeechServices()
        let intel = config(.whisper)
        let live = await services.liveEngine(config: intel)
        let final = await services.finalEngine(config: intel)
        #expect(live.id == "whisper:ggml-small.en.bin")
        #expect(final.id == "whisper:ggml-large-v3-turbo-q5_0.bin")
        let parakeetLive = await services.liveEngine(config: config(.parakeet))
        let parakeetFinal = await services.finalEngine(config: config(.parakeet))
        #expect(parakeetLive.id == "parakeet:v2")
        #expect(ObjectIdentifier(parakeetLive as AnyObject) == ObjectIdentifier(parakeetFinal as AnyObject))
    }
}
