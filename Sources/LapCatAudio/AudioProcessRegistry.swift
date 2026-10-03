import CoreAudio
import Foundation

public struct AudioProcessInfo: Sendable, Equatable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let name: String
    public let isRunningInput: Bool
    public let isRunningOutput: Bool
}

/// Core Audio's view of processes using audio (pattern: insidegui/AudioCap `AudioProcessController.swift`).
public enum AudioProcessRegistry {
    /// Every process currently registered with the audio HAL.
    public static func processes() -> [AudioProcessInfo] {
        CoreAudioProperty.objectList(CoreAudioProperty.system, kAudioHardwarePropertyProcessObjectList)
            .compactMap(info(forObjectID:))
    }

    public static func info(forObjectID objectID: AudioObjectID) -> AudioProcessInfo? {
        guard let pid = CoreAudioProperty.read(objectID, kAudioProcessPropertyPID, default: pid_t(-1)), pid >= 0 else {
            return nil
        }
        let bundleID = CoreAudioProperty.string(objectID, kAudioProcessPropertyBundleID).flatMap {
            $0.isEmpty ? nil : $0
        }
        return AudioProcessInfo(
            objectID: objectID,
            pid: pid,
            bundleID: bundleID,
            name: processName(pid: pid) ?? bundleID ?? "pid \(pid)",
            isRunningInput: CoreAudioProperty.bool(objectID, kAudioProcessPropertyIsRunningInput),
            isRunningOutput: CoreAudioProperty.bool(objectID, kAudioProcessPropertyIsRunningOutput)
        )
    }

    public static func process(forPID pid: pid_t) -> AudioProcessInfo? {
        objectID(forPID: pid).flatMap(info(forObjectID:))
    }

    public static func objectID(forPID pid: pid_t) -> AudioObjectID? {
        let id = CoreAudioProperty.read(
            CoreAudioProperty.system, kAudioHardwarePropertyTranslatePIDToProcessObject,
            default: AudioObjectID(kAudioObjectUnknown), qualifier: pid
        )
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    /// The running instance of `bundleID` that is producing output, else any instance. Helper
    /// processes count too (Chrome plays audio from `com.google.Chrome.helper`; Arc's helper is
    /// `company.thebrowser.browser.helper`), matched case-insensitively by prefix.
    public static func objectID(forBundleID bundleID: String) -> AudioObjectID? {
        let wanted = bundleID.lowercased()
        let candidates = processes().filter { process in
            guard let id = process.bundleID?.lowercased() else { return false }
            return id == wanted || id.hasPrefix(wanted + ".")
        }
        return (candidates.first(where: \.isRunningOutput) ?? candidates.first)?.objectID
    }

    /// Whether the process object is currently producing output.
    public static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        CoreAudioProperty.bool(objectID, kAudioProcessPropertyIsRunningOutput)
    }

    /// Whether any process other than this one is producing output.
    static func anyOtherProcessRunningOutput() -> Bool {
        let own = getpid()
        return processes().contains { $0.pid != own && $0.isRunningOutput }
    }

    private static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXCOMLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
