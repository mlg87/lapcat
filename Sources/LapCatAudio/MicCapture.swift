import AudioToolbox
import AVFoundation
import Foundation
import os

/// Microphone capture through `AVAudioEngine`. The tap block only copies the buffer and hands it
/// to `onBuffer`, which must enqueue it. Restarts itself on `AVAudioEngineConfigurationChange`
/// (device unplug, sleep/wake) and reports that through `onConfigurationChange`.
final class MicCapture: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "MicCapture")

    private let deviceUID: String?
    private let voiceProcessing: Bool
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onConfigurationChange: @Sendable () -> Void
    /// Serialises engine (re)configuration; engine calls never run on the audio thread.
    private let controlQueue = DispatchQueue(label: "com.lapcat.audio.mic-control")
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var running = false

    init(
        deviceUID: String?,
        voiceProcessing: Bool,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) {
        self.deviceUID = deviceUID
        self.voiceProcessing = voiceProcessing
        self.onBuffer = onBuffer
        self.onConfigurationChange = onConfigurationChange
    }

    /// Starts the engine and returns the input's native format.
    func start() throws(AudioCaptureError) -> AVAudioFormat {
        var result: Result<AVAudioFormat, AudioCaptureError> = .failure(.micUnavailable("not started"))
        controlQueue.sync {
            result = Result { () throws(AudioCaptureError) in try self.configureAndStart() }
            if case .success = result { self.running = true }
        }
        return try result.get()
    }

    func stop() {
        controlQueue.sync {
            running = false
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    private func configureAndStart() throws(AudioCaptureError) -> AVAudioFormat {
        let input = engine.inputNode
        if let deviceUID {
            guard let deviceID = CoreAudioProperty.device(forUID: deviceUID), let unit = input.audioUnit else {
                throw .micUnavailable("input device \(deviceUID) not found")
            }
            var device = deviceID
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw .micUnavailable("selecting \(deviceUID) failed (\(status.fourCC))") }
        }
        if input.isVoiceProcessingEnabled != voiceProcessing {
            do { try input.setVoiceProcessingEnabled(voiceProcessing) } catch {
                Self.logger.error("voice processing toggle failed: \(error, privacy: .public)")
            }
        }
        if voiceProcessing {
            // Keep the meeting app audible: voice processing ducks other output by default.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw .micUnavailable("input has no channels")
        }
        let onBuffer = onBuffer
        input.installTap(onBus: 0, bufferSize: 4800, format: nil) { buffer, _ in
            if let copy = buffer.ownedCopy() { onBuffer(copy) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw .micUnavailable(error.localizedDescription)
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.controlQueue.async { self.restartAfterConfigurationChange() }
            }
        }
        return format
    }

    private func restartAfterConfigurationChange() {
        guard running else { return }
        Self.logger.info("engine configuration changed; restarting")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { _ = try configureAndStart() } catch {
            Self.logger.error("mic restart failed: \(error.description, privacy: .public)")
        }
        onConfigurationChange()
    }
}

extension AVAudioPCMBuffer {
    /// A deep copy whose memory this buffer's producer cannot reuse.
    func ownedCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            let bytes = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            memcpy(to, from, bytes)
            destination[index].mDataByteSize = UInt32(bytes)
        }
        return copy
    }
}
