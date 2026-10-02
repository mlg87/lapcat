import AVFoundation
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

/// Fallback system-channel source (PRD FR-2.4): ScreenCaptureKit audio of one app (or every app
/// but LapCat). Needs the Screen Recording permission. Sample buffers are copied into owned PCM
/// buffers and handed to `onBuffer`, which must enqueue them.
final class SCKAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "SCKAudioCapture")

    private let pid: pid_t?
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let sampleQueue = DispatchQueue(label: "com.lapcat.audio.sck", qos: .userInitiated)
    private var stream: SCStream?

    /// `pid` = the app to capture; nil = all apps except this process.
    init(pid: pid_t?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.pid = pid
        self.onBuffer = onBuffer
    }

    func start() async throws(AudioCaptureError) {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) } catch {
            throw .screenCapture(error.localizedDescription)
        }
        guard let display = content.displays.first else { throw .screenCapture("no display") }
        let filter: SCContentFilter
        if let pid {
            guard let app = content.applications.first(where: { $0.processID == pid }) else {
                throw .screenCapture("application pid \(pid) not shareable")
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            throw .screenCapture(error.localizedDescription)
        }
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return }
        onBuffer(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Self.logger.error("stream stopped: \(error, privacy: .public)")
    }
}
