import CoreAudio
import Foundation

/// The two recorded channels: the user's microphone ("Me") and the meeting app's output ("Them").
public enum AudioChannel: String, Sendable, CaseIterable {
    case mic, system
}

/// 16 kHz mono Float32 samples of one channel. `tStartMs` is measured on the session clock
/// (samples delivered so far on that channel; pausing stops delivery).
public struct AudioChunk: Sendable {
    public let channel: AudioChannel
    public let samples: [Float]
    public let tStartMs: Int

    public init(channel: AudioChannel, samples: [Float], tStartMs: Int) {
        self.channel = channel
        self.samples = samples
        self.tStartMs = tStartMs
    }
}

/// What the system channel taps.
public enum TapScope: Sendable, Equatable {
    /// One process, by its Core Audio process object (see `AudioProcessRegistry`).
    case process(AudioObjectID)
    /// Every process's output except LapCat's own.
    case systemExcludingSelf
}

/// File names of the per-channel recordings inside a meeting's audio directory.
///
/// ADTS AAC-LC (16 kHz mono, 48 kbps), not AAC-in-CAF: an ADTS stream is self-framing, so a
/// crash leaves a playable file. AAC in CAF needs a packet table that is only written at close.
public enum CaptureFiles {
    public static let mic = "mic.aac"
    public static let system = "them.aac"
    /// Value for `audio_file.codec`.
    public static let codec = "aac-adts"

    public static func fileName(for channel: AudioChannel) -> String {
        channel == .mic ? mic : system
    }
}

public enum AudioCaptureError: Error, Sendable, Equatable, CustomStringConvertible {
    case tapCreation(OSStatus)
    case aggregateCreation(OSStatus)
    case ioProc(OSStatus)
    case tapFormatUnavailable
    case systemAudioPermissionMissing
    case systemAudioUnavailable
    case screenCapture(String)
    case micUnavailable(String)
    case fileWrite(String)
    case alreadyStarted

    public var description: String {
        switch self {
        case .tapCreation(let status): "process tap creation failed (\(status))"
        case .aggregateCreation(let status): "aggregate device creation failed (\(status))"
        case .ioProc(let status): "audio IO proc failed (\(status))"
        case .tapFormatUnavailable: "process tap format unavailable"
        case .systemAudioPermissionMissing: "System Audio Recording permission missing"
        case .systemAudioUnavailable: "system audio unavailable; recording microphone only"
        case .screenCapture(let message): "screen-recording audio capture failed: \(message)"
        case .micUnavailable(let message): "microphone unavailable: \(message)"
        case .fileWrite(let message): "audio file write failed: \(message)"
        case .alreadyStarted: "capture session already started"
        }
    }
}

public enum CaptureEvent: Sendable {
    /// A channel's source started; `format` describes the source's native stream format.
    case sourceStarted(AudioChannel, format: String)
    /// The default output device or the microphone's configuration changed.
    case deviceChanged(AudioChannel)
    /// The process tap and its aggregate device were destroyed and recreated.
    case tapRebuilt
    /// The system channel switched to ScreenCaptureKit audio.
    case fallbackEngaged
    /// The process tap delivered non-silent audio: System Audio Recording is granted.
    case systemAudioTapSucceeded
    case error(AudioCaptureError)
}

public struct CaptureSummary: Sendable {
    public let micDuration: TimeInterval
    public let systemDuration: TimeInterval
    public let usedFallback: Bool
    public let micFile: URL
    public let systemFile: URL
}
