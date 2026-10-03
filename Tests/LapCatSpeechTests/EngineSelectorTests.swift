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
    func explicitWhisperAppliesToBothPassesOnEitherArchitecture(architecture: CPUArchitecture) {
        let whisper = EngineSelector(config: config(.whisper), architecture: architecture)
        #expect(whisper.liveEngine() == .whisper(modelFile: "ggml-small.en.bin"))
        #expect(whisper.finalEngine() == .whisper(modelFile: "ggml-large-v3-turbo-q5_0.bin"))
    }

    @Test func explicitParakeetAppliesToBothPassesOnArm64() {
        let parakeet = EngineSelector(config: config(.parakeet), architecture: .arm64)
        #expect(parakeet.liveEngine() == .parakeet(version: "v2"))
        #expect(parakeet.finalEngine() == .parakeet(version: "v2"))
    }

    @Test func explicitParakeetFallsBackToWhisperOnIntel() {
        // FluidAudio Parakeet crashes the process with SIGFPE on x86_64 (lc-143 spike).
        let parakeet = EngineSelector(config: config(.parakeet), architecture: .x86_64)
        #expect(parakeet.liveEngine() == .whisper(modelFile: "ggml-small.en.bin"))
        #expect(parakeet.finalEngine() == .whisper(modelFile: "ggml-large-v3-turbo-q5_0.bin"))
    }

    @Test func servicesReuseOneEnginePerRoleAndNeverShareLiveWithFinal() async {
        let services = SpeechServices()
        let directory = URL(fileURLWithPath: "/tmp/models")
        let live = await services.liveEngine(config: config(.whisper))
        let liveAgain = await services.engine(
            for: .whisper(modelFile: "ggml-small.en.bin"), role: .live, modelsDirectory: directory)
        #expect(live.id == "whisper:ggml-small.en.bin")
        #expect(ObjectIdentifier(live as AnyObject) == ObjectIdentifier(liveAgain as AnyObject))
        // Same model for both passes (the Intel default): still two instances, so a long final pass
        // never blocks live transcription.
        let sameModel = SpeechConfig(
            engine: .whisper, whisperLiveModel: "ggml-small.en.bin",
            whisperFinalModel: "ggml-small.en.bin", modelsDirectory: directory)
        let final = await services.finalEngine(config: sameModel)
        #expect(final.id == live.id)
        #expect(ObjectIdentifier(live as AnyObject) != ObjectIdentifier(final as AnyObject))
    }
}
