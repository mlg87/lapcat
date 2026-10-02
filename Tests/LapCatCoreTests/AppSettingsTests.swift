import Foundation
import Testing
@testable import LapCatCore

@MainActor
struct AppSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "lapcat.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsMatchThePlan() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.userDisplayName == NSFullUserName())
        #expect(s.llmProviderOrder == ["claude-cli", "anthropic-api", "local"])
        #expect(s.llmModel(provider: "claude-cli", task: "classify") == "haiku")
        #expect(s.llmModel(provider: "anthropic-api", task: "chat") == "claude-sonnet-5-5")
        #expect(s.llmModel(provider: "local", task: "enhance") == "Qwen3-4B-Q4_K_M.gguf")
        #expect(s.llmClaudePath == nil)
        #expect(!s.llmOfflineOnly)
        #expect(s.sttEngine == "auto")
        #expect(s.sttWhisperLiveModel == "ggml-small.en.bin")
        #expect(s.sttParakeetVersion == "v2")
        #if arch(arm64)
        #expect(s.sttLiveHypothesis)
        #else
        #expect(!s.sttLiveHypothesis)
        #endif
        #expect(s.audioTapScope == "app")
        #expect(s.audioInputDeviceUID == nil)
        #expect(s.audioVoiceProcessing)
        #expect(s.audioRetention == .thirtyDays)
        #expect(s.detectEnabled)
        #expect(s.detectBundleIDs.first == "us.zoom.xos" && s.detectBundleIDs.count == 7)
        #expect(s.detectUseCalendarSignal && !s.detectUseBrowserTabSignal)
        #expect(s.speakersAdaptersEnabled && s.speakersSelectorsZoom == nil && s.speakersSelectorsMeet == nil)
        #expect(s.consentReminderEnabled)
        #expect(s.consentCannedMessage.hasPrefix("Heads up: I'm taking AI notes"))
        #expect(s.exportAutoExportFolder == nil)
        #expect(s.templateDefaultID == "auto")
        #expect(s.hotKeys[.newNote].displayString == "⌃⌥N")
        #expect(!s.onboardingCompleted)
    }

    @Test func changesPersistToANewInstanceAndNilRestoresDefault() {
        let defaults = freshDefaults()
        let s = AppSettings(defaults: defaults)
        s.llmOfflineOnly = true
        s.llmProviderOrder = ["local", "claude-cli"]
        s.setLLMModel("opus", provider: "claude-cli", task: "enhance")
        s.audioRetention = .never
        s.audioInputDeviceUID = "BuiltInMic"
        s.llmClaudePath = "/opt/claude"
        s.onboardingCompleted = true

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.llmOfflineOnly)
        #expect(reloaded.llmProviderOrder == ["local", "claude-cli"])
        #expect(reloaded.llmModel(provider: "claude-cli", task: "enhance") == "opus")
        #expect(reloaded.llmModel(provider: "claude-cli", task: "chat") == "sonnet")
        #expect(reloaded.audioRetention == .never)
        #expect(reloaded.audioInputDeviceUID == "BuiltInMic")
        #expect(reloaded.onboardingCompleted)
        #expect(defaults.string(forKey: "llm.model.claude-cli.enhance") == "opus")

        reloaded.llmClaudePath = nil
        #expect(AppSettings(defaults: defaults).llmClaudePath == nil)
    }

    @Test func retentionDeadlines() {
        let t = Date(timeIntervalSince1970: 0)
        #expect(AudioRetention.sevenDays.retainedUntil(from: t) == Date(timeIntervalSince1970: 7 * 86_400))
        #expect(AudioRetention.thirtyDays.retainedUntil(from: t) == Date(timeIntervalSince1970: 30 * 86_400))
        #expect(AudioRetention.forever.retainedUntil(from: t) == nil)
        #expect(AudioRetention.never.retainedUntil(from: t) == nil)
    }
}
