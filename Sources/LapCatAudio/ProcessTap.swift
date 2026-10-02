import AVFoundation
import CoreAudio
import Foundation
import os

/// A Core Audio process tap wrapped in a private aggregate device
/// (pattern: insidegui/AudioCap `ProcessTap.swift`).
///
/// The IO block only copies the tap's samples into an owned buffer and hands it to `onBuffer`,
/// which must enqueue (never process) it.
public final class ProcessTap: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "ProcessTap")

    let scope: TapScope
    let format: AVAudioFormat
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.lapcat.audio.tap-io", qos: .userInteractive)

    init(scope: TapScope) throws(AudioCaptureError) {
        self.scope = scope
        let description: CATapDescription
        switch scope {
        case .process(let objectID):
            description = CATapDescription(stereoMixdownOfProcesses: [objectID])
        case .systemExcludingSelf:
            let own = AudioProcessRegistry.objectID(forPID: getpid())
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else { throw Self.classify(tapStatus, else: .tapCreation(tapStatus)) }
        self.tapID = tapID

        guard var asbd = CoreAudioProperty.read(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription()),
              let format = AVAudioFormat(streamDescription: &asbd)
        else {
            AudioHardwareDestroyProcessTap(tapID)
            throw .tapFormatUnavailable
        }
        self.format = format

        guard let outputID = CoreAudioProperty.defaultOutputDevice(),
              let outputUID = CoreAudioProperty.string(outputID, kAudioDevicePropertyDeviceUID)
        else {
            AudioHardwareDestroyProcessTap(tapID)
            throw .aggregateCreation(kAudioHardwareBadDeviceError)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LapCat-Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString],
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw Self.classify(aggregateStatus, else: .aggregateCreation(aggregateStatus))
        }
        self.aggregateID = aggregateID
        Self.logger.info("tap \(tapID) on aggregate \(aggregateID), format \(format, privacy: .public)")
    }

    /// Starts IO. `onBuffer` runs on the IO queue with an owned copy of the tap's samples.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws(AudioCaptureError) {
        let format = format
        // The aggregate's input lists the sub-device's input streams (if any) before the tap's.
        let tapBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard list.count >= tapBufferCount, bytesPerFrame > 0 else { return }
            let source = list[(list.count - tapBufferCount)...]
            let frames = Int(source[source.startIndex].mDataByteSize) / bytesPerFrame
            guard frames > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { return }
            copy.frameLength = AVAudioFrameCount(frames)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (offset, buffer) in source.enumerated() where offset < destination.count {
                guard let from = buffer.mData, let to = destination[offset].mData else { continue }
                memcpy(to, from, min(Int(buffer.mDataByteSize), Int(destination[offset].mDataByteSize)))
            }
            onBuffer(copy)
        }
        guard status == noErr, let procID else { throw .ioProc(status) }
        self.procID = procID
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else { throw Self.classify(startStatus, else: .ioProc(startStatus)) }
    }

    /// Stops IO and destroys IOProc → aggregate → tap, in that order. Idempotent.
    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                self.procID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { invalidate() }

    /// Runs a short-lived `.systemExcludingSelf` tap for ~0.5 s. Creating it makes macOS show the
    /// System Audio Recording prompt (first time) and list the app in System Settings. Returns
    /// `true` when the tap was created and its IO callback ran. A callback can run while the
    /// permission is denied (it then delivers silence), so `true` means "tap works", not "granted".
    public static func requestPermissionByProbe() async -> Bool {
        let ran = OSAllocatedUnfairLock(initialState: false)
        do {
            let tap = try ProcessTap(scope: .systemExcludingSelf)
            try tap.start { _ in ran.withLock { $0 = true } }
            try? await Task.sleep(for: .milliseconds(500))
            tap.invalidate()
        } catch {
            logger.error("permission probe failed: \(error.description, privacy: .public)")
            return false
        }
        return ran.withLock { $0 }
    }

    /// Maps HAL statuses that mean "not permitted" to `.systemAudioPermissionMissing`.
    private static func classify(_ status: OSStatus, else fallback: AudioCaptureError) -> AudioCaptureError {
        switch status {
        case kAudioHardwareIllegalOperationError, kAudioDevicePermissionsError: .systemAudioPermissionMissing
        default: fallback
        }
    }
}
