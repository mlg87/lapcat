import CoreAudio
import Foundation

/// An audio device that can record (`audio.inputDeviceUID` stores `uid`).
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    public let uid: String
    public let name: String
    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public enum AudioDevices {
    /// Every device with at least one input channel, in Core Audio's order.
    public static func inputDevices() -> [AudioInputDevice] {
        CoreAudioProperty.objectList(CoreAudioProperty.system, kAudioHardwarePropertyDevices).compactMap { device in
            guard inputChannelCount(device) > 0,
                  let uid = CoreAudioProperty.string(device, kAudioDevicePropertyDeviceUID)
            else { return nil }
            let name = CoreAudioProperty.string(device, kAudioObjectPropertyName) ?? uid
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = CoreAudioProperty.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
