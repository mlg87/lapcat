import FluidAudio
import Foundation

/// Speech settings the app builds from `AppSettings` (`stt.*`) — this library never reads UserDefaults.
public struct SpeechConfig: Sendable, Equatable {
    public enum EngineChoice: String, Sendable, CaseIterable { case auto, whisper, parakeet }

    public var engine: EngineChoice
    public var whisperLiveModel: String
    public var whisperFinalModel: String
    /// `"v2"` | `"v3"`.
    public var parakeetVersion: String
    public var modelsDirectory: URL

    public init(
        engine: EngineChoice = .auto,
        whisperLiveModel: String = "ggml-small.en.bin",
        whisperFinalModel: String = "ggml-large-v3-turbo-q5_0.bin",
        parakeetVersion: String = "v2",
        modelsDirectory: URL
    ) {
        self.engine = engine
        self.whisperLiveModel = whisperLiveModel
        self.whisperFinalModel = whisperFinalModel
        self.parakeetVersion = parakeetVersion
        self.modelsDirectory = modelsDirectory
    }
}

public enum CPUArchitecture: Sendable {
    case arm64, x86_64

    public static var current: CPUArchitecture {
        #if arch(arm64)
        .arm64
        #else
        .x86_64
        #endif
    }
}

/// Which engine (and model) serves a pass.
public enum EngineSpec: Sendable, Hashable {
    case whisper(modelFile: String)
    case parakeet(version: String)

    /// Matches `TranscriptionEngine.id`.
    public var id: String {
        switch self {
        case .whisper(let file): "whisper:\(file)"
        case .parakeet(let version): "parakeet:\(version)"
        }
    }

    /// The catalog model file this spec needs locally (Parakeet models are FluidAudio-managed).
    public var requiredModelFile: String? {
        if case .whisper(let file) = self { file } else { nil }
    }
}

/// `auto` ⇒ Parakeet for both passes on arm64, whisper live/final models on x86_64.
/// An explicit `whisper` / `parakeet` choice applies to both passes on either architecture.
public struct EngineSelector: Sendable {
    public var config: SpeechConfig
    public var architecture: CPUArchitecture

    public init(config: SpeechConfig, architecture: CPUArchitecture = .current) {
        self.config = config
        self.architecture = architecture
    }

    public func liveEngine() -> EngineSpec { spec(whisperModel: config.whisperLiveModel) }
    public func finalEngine() -> EngineSpec { spec(whisperModel: config.whisperFinalModel) }

    private func spec(whisperModel: String) -> EngineSpec {
        switch (config.engine, architecture) {
        case (.parakeet, _), (.auto, .arm64): .parakeet(version: config.parakeetVersion)
        case (.whisper, _), (.auto, .x86_64): .whisper(modelFile: whisperModel)
        }
    }
}

/// Owns engine instances: one per engine id, created on first use and shared by live and final passes.
public actor SpeechServices {
    private var engines: [String: any TranscriptionEngine] = [:]

    public init() {}

    /// Blocks (or re-allows) every FluidAudio network fetch; the app mirrors `llm.offlineOnly` here.
    public static func setOffline(_ offline: Bool) {
        ModelHub.offlineMode = offline
    }

    public func liveEngine(config: SpeechConfig) -> any TranscriptionEngine {
        engine(for: EngineSelector(config: config).liveEngine(), modelsDirectory: config.modelsDirectory)
    }

    public func finalEngine(config: SpeechConfig) -> any TranscriptionEngine {
        engine(for: EngineSelector(config: config).finalEngine(), modelsDirectory: config.modelsDirectory)
    }

    public func engine(for spec: EngineSpec, modelsDirectory: URL) -> any TranscriptionEngine {
        if let cached = engines[spec.id] { return cached }
        let engine: any TranscriptionEngine = switch spec {
        case .whisper(let file): WhisperCppEngine(modelURL: modelsDirectory.appending(path: file, directoryHint: .notDirectory))
        case .parakeet(let version): ParakeetEngine(version: version)
        }
        engines[spec.id] = engine
        return engine
    }

    /// Unloads and forgets every cached engine (e.g. after the settings changed the engine choice).
    public func unloadAll() async {
        let current = engines.values
        engines.removeAll()
        for engine in current { await engine.unload() }
    }
}
