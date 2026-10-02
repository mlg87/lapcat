import Foundation
import Observation

/// How long a meeting's audio is kept after recording (`audio.retention`).
public enum AudioRetention: String, Sendable, CaseIterable {
    case never
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case forever

    /// Value for `meeting.audio_retained_until`; nil for `forever` and `never` (deleted after the final pass).
    public func retainedUntil(from date: Date) -> Date? {
        switch self {
        case .never, .forever: nil
        case .sevenDays: date.addingTimeInterval(7 * 86_400)
        case .thirtyDays: date.addingTimeInterval(30 * 86_400)
        }
    }
}

/// User settings backed by `UserDefaults`; every property writes through on set.
/// Libraries other than LapCatCore never read this — the app builds their config from it.
@Observable @MainActor
public final class AppSettings {
    @ObservationIgnored public let defaults: UserDefaults

    public enum Key {
        public static let userDisplayName = "userDisplayName"
        public static let llmProviderOrder = "llm.providerOrder"
        public static let llmClaudePath = "llm.claudePath"
        public static let llmOfflineOnly = "llm.offlineOnly"
        public static let sttEngine = "stt.engine"
        public static let sttWhisperLiveModel = "stt.whisperLiveModel"
        public static let sttWhisperFinalModel = "stt.whisperFinalModel"
        public static let sttParakeetVersion = "stt.parakeetVersion"
        public static let sttLiveHypothesis = "stt.liveHypothesis"
        public static let audioTapScope = "audio.tapScope"
        public static let audioInputDeviceUID = "audio.inputDeviceUID"
        public static let audioVoiceProcessing = "audio.voiceProcessing"
        public static let audioRetention = "audio.retention"
        public static let detectEnabled = "detect.enabled"
        public static let detectBundleIDs = "detect.bundleIDs"
        public static let detectUseCalendarSignal = "detect.useCalendarSignal"
        public static let detectUseBrowserTabSignal = "detect.useBrowserTabSignal"
        public static let speakersAdaptersEnabled = "speakers.adapters.enabled"
        public static let speakersSelectorsZoom = "speakers.selectors.zoom"
        public static let speakersSelectorsMeet = "speakers.selectors.meet"
        public static let consentReminderEnabled = "consent.reminderEnabled"
        public static let consentCannedMessage = "consent.cannedMessage"
        public static let exportAutoExportFolder = "export.autoExportFolder"
        public static let templateDefaultID = "template.defaultID"
        public static let onboardingCompleted = "onboarding.completed"
        /// `llm.model.<provider>.<task>`, e.g. `llm.model.claude-cli.enhance`.
        public static func llmModel(provider: String, task: String) -> String { "llm.model.\(provider).\(task)" }
    }

    public enum Default {
        public static let llmProviderOrder = ["claude-cli", "anthropic-api", "local"]
        public static let llmTasks = ["enhance", "chat", "classify"]
        /// provider → task → model.
        public static let llmModels: [String: [String: String]] = [
            "claude-cli": ["enhance": "sonnet", "chat": "sonnet", "classify": "haiku"],
            "anthropic-api": ["enhance": "claude-haiku-4-5", "chat": "claude-sonnet-5-5", "classify": "claude-haiku-4-5"],
            "local": ["enhance": "Qwen3-4B-Q4_K_M.gguf", "chat": "Qwen3-4B-Q4_K_M.gguf", "classify": "Qwen3-4B-Q4_K_M.gguf"],
        ]
        public static let sttEngine = "auto"
        public static let sttWhisperLiveModel = "ggml-small.en.bin"
        #if arch(arm64)
        public static let sttWhisperFinalModel = "ggml-large-v3-turbo-q5_0.bin"
        #else
        /// Measured on Intel: large-v3-turbo-q5_0 runs at RTF 0.46 (~130 min per 60-min meeting);
        /// small.en at RTF 2.24 (~27 min) fits the post-meeting budget.
        public static let sttWhisperFinalModel = "ggml-small.en.bin"
        #endif
        public static let sttParakeetVersion = "v2"
        #if arch(arm64)
        public static let sttLiveHypothesis = true
        #else
        public static let sttLiveHypothesis = false
        #endif
        public static let audioTapScope = "app"
        public static let audioRetention = AudioRetention.thirtyDays
        public static let detectBundleIDs = [
            "us.zoom.xos", "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
            "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
        ]
        public static let consentCannedMessage =
            "Heads up: I'm taking AI notes for this meeting with a local app on my Mac. Tell me if you'd rather I didn't."
        public static let templateDefaultID = "auto"
    }

    public var userDisplayName: String { didSet { defaults.set(userDisplayName, forKey: Key.userDisplayName) } }
    public var llmProviderOrder: [String] { didSet { defaults.set(llmProviderOrder, forKey: Key.llmProviderOrder) } }
    /// provider → task → model, persisted per entry under `llm.model.<provider>.<task>`.
    public private(set) var llmModels: [String: [String: String]]
    /// nil = search the default locations.
    public var llmClaudePath: String? { didSet { setOptional(llmClaudePath, Key.llmClaudePath) } }
    public var llmOfflineOnly: Bool { didSet { defaults.set(llmOfflineOnly, forKey: Key.llmOfflineOnly) } }
    /// `auto` | `whisper` | `parakeet`.
    public var sttEngine: String { didSet { defaults.set(sttEngine, forKey: Key.sttEngine) } }
    public var sttWhisperLiveModel: String { didSet { defaults.set(sttWhisperLiveModel, forKey: Key.sttWhisperLiveModel) } }
    public var sttWhisperFinalModel: String { didSet { defaults.set(sttWhisperFinalModel, forKey: Key.sttWhisperFinalModel) } }
    public var sttParakeetVersion: String { didSet { defaults.set(sttParakeetVersion, forKey: Key.sttParakeetVersion) } }
    public var sttLiveHypothesis: Bool { didSet { defaults.set(sttLiveHypothesis, forKey: Key.sttLiveHypothesis) } }
    /// `app` | `system`.
    public var audioTapScope: String { didSet { defaults.set(audioTapScope, forKey: Key.audioTapScope) } }
    /// nil = system default input.
    public var audioInputDeviceUID: String? { didSet { setOptional(audioInputDeviceUID, Key.audioInputDeviceUID) } }
    public var audioVoiceProcessing: Bool { didSet { defaults.set(audioVoiceProcessing, forKey: Key.audioVoiceProcessing) } }
    public var audioRetention: AudioRetention { didSet { defaults.set(audioRetention.rawValue, forKey: Key.audioRetention) } }
    public var detectEnabled: Bool { didSet { defaults.set(detectEnabled, forKey: Key.detectEnabled) } }
    public var detectBundleIDs: [String] { didSet { defaults.set(detectBundleIDs, forKey: Key.detectBundleIDs) } }
    public var detectUseCalendarSignal: Bool { didSet { defaults.set(detectUseCalendarSignal, forKey: Key.detectUseCalendarSignal) } }
    public var detectUseBrowserTabSignal: Bool { didSet { defaults.set(detectUseBrowserTabSignal, forKey: Key.detectUseBrowserTabSignal) } }
    public var speakersAdaptersEnabled: Bool { didSet { defaults.set(speakersAdaptersEnabled, forKey: Key.speakersAdaptersEnabled) } }
    /// Selector JSON override; nil = compiled defaults.
    public var speakersSelectorsZoom: String? { didSet { setOptional(speakersSelectorsZoom, Key.speakersSelectorsZoom) } }
    public var speakersSelectorsMeet: String? { didSet { setOptional(speakersSelectorsMeet, Key.speakersSelectorsMeet) } }
    public var consentReminderEnabled: Bool { didSet { defaults.set(consentReminderEnabled, forKey: Key.consentReminderEnabled) } }
    public var consentCannedMessage: String { didSet { defaults.set(consentCannedMessage, forKey: Key.consentCannedMessage) } }
    /// Directory path; nil = auto-export off.
    public var exportAutoExportFolder: String? { didSet { setOptional(exportAutoExportFolder, Key.exportAutoExportFolder) } }
    public var templateDefaultID: String { didSet { defaults.set(templateDefaultID, forKey: Key.templateDefaultID) } }
    public var hotKeys: HotKeyBindings { didSet { hotKeys.save(to: defaults) } }
    public var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }

        userDisplayName = value(Key.userDisplayName, NSFullUserName())
        llmProviderOrder = value(Key.llmProviderOrder, Default.llmProviderOrder)
        llmModels = Default.llmModels.reduce(into: [:]) { result, entry in
            let (provider, tasks) = entry
            result[provider] = tasks.reduce(into: [:]) { models, task in
                models[task.key] = value(Key.llmModel(provider: provider, task: task.key), task.value)
            }
        }
        llmClaudePath = defaults.string(forKey: Key.llmClaudePath)
        llmOfflineOnly = value(Key.llmOfflineOnly, false)
        sttEngine = value(Key.sttEngine, Default.sttEngine)
        sttWhisperLiveModel = value(Key.sttWhisperLiveModel, Default.sttWhisperLiveModel)
        sttWhisperFinalModel = value(Key.sttWhisperFinalModel, Default.sttWhisperFinalModel)
        sttParakeetVersion = value(Key.sttParakeetVersion, Default.sttParakeetVersion)
        sttLiveHypothesis = value(Key.sttLiveHypothesis, Default.sttLiveHypothesis)
        audioTapScope = value(Key.audioTapScope, Default.audioTapScope)
        audioInputDeviceUID = defaults.string(forKey: Key.audioInputDeviceUID)
        audioVoiceProcessing = value(Key.audioVoiceProcessing, true)
        audioRetention = defaults.string(forKey: Key.audioRetention).flatMap(AudioRetention.init(rawValue:))
            ?? Default.audioRetention
        detectEnabled = value(Key.detectEnabled, true)
        detectBundleIDs = value(Key.detectBundleIDs, Default.detectBundleIDs)
        detectUseCalendarSignal = value(Key.detectUseCalendarSignal, true)
        detectUseBrowserTabSignal = value(Key.detectUseBrowserTabSignal, false)
        speakersAdaptersEnabled = value(Key.speakersAdaptersEnabled, true)
        speakersSelectorsZoom = defaults.string(forKey: Key.speakersSelectorsZoom)
        speakersSelectorsMeet = defaults.string(forKey: Key.speakersSelectorsMeet)
        consentReminderEnabled = value(Key.consentReminderEnabled, true)
        consentCannedMessage = value(Key.consentCannedMessage, Default.consentCannedMessage)
        exportAutoExportFolder = defaults.string(forKey: Key.exportAutoExportFolder)
        templateDefaultID = value(Key.templateDefaultID, Default.templateDefaultID)
        hotKeys = HotKeyBindings.load(from: defaults)
        onboardingCompleted = value(Key.onboardingCompleted, false)
    }

    /// Model for `provider` (`claude-cli` | `anthropic-api` | `local`) and `task` (`enhance` | `chat` | `classify`).
    public func llmModel(provider: String, task: String) -> String? {
        llmModels[provider]?[task]
    }

    public func setLLMModel(_ model: String, provider: String, task: String) {
        llmModels[provider, default: [:]][task] = model
        defaults.set(model, forKey: Key.llmModel(provider: provider, task: task))
    }

    private func setOptional(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
