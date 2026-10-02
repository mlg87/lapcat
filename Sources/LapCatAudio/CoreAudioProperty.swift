import CoreAudio
import Foundation

/// Typed reads of Core Audio object properties (pattern: insidegui/AudioCap `CoreAudioUtils.swift`).
enum CoreAudioProperty {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? result : nil
    }

    static func read<T, Q>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T, qualifier: Q
    ) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        var qualifier = qualifier
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            withUnsafeMutablePointer(to: &result) {
                AudioObjectGetPropertyData(
                    object, &address, UInt32(MemoryLayout<Q>.size), qualifierPointer, &size, $0
                )
            }
        }
        return status == noErr ? result : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func bool(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        (read(object, selector, default: UInt32(0)) ?? 0) != 0
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        let id = read(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(kAudioObjectUnknown))
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func device(forUID uid: String) -> AudioDeviceID? {
        let id = read(
            system, kAudioHardwarePropertyTranslateUIDToDevice,
            default: AudioDeviceID(kAudioObjectUnknown), qualifier: uid as CFString
        )
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }
}

extension OSStatus {
    /// Four-character code rendering for logs (`'nope'`), falling back to the number.
    var fourCC: String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: self).bigEndian) { Array($0) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(self) }
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }
}
