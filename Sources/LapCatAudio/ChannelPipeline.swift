import AVFoundation
import Foundation
import os

/// One per channel. Sources (process tap, mic engine, ScreenCaptureKit) call `ingest` from their
/// audio threads; everything else — mixdown, 16 kHz conversion, file writes, level metering,
/// tap-health checks and chunk fan-out — runs on this pipeline's serial queue.
///
/// All mutable state is confined to `queue`.
final class ChannelPipeline: @unchecked Sendable {
    enum Mixdown { case average, firstChannel }

    struct Callbacks: Sendable {
        var chunk: @Sendable (AudioChunk) -> Void
        var level: @Sendable (Float) -> Void
        /// First non-silent samples of the current source.
        var signal: @Sendable () -> Void = {}
        /// The source went silent for 10 s while it reports running output (system channel only).
        var silentWhileActive: @Sendable () -> Void = {}
        var error: @Sendable (AudioCaptureError) -> Void
    }

    static let sampleRate = 16_000
    /// Emitted chunk size: 100 ms.
    static let chunkSamples = 1_600
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "ChannelPipeline")
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false
    )!

    let channel: AudioChannel
    let fileURL: URL
    private let mixdown: Mixdown
    private let callbacks: Callbacks
    private let queue: DispatchQueue

    private var file: AVAudioFile?
    private var writeFailed = false
    private var normalizer: AVAudioConverter?
    private var resampler: AVAudioConverter?
    private var pending: [Float] = []
    private var delivered = 0
    private var paused = false
    private var finished = false
    private var signalSeen = false

    private var health: TapHealthMonitor?
    private var sourceActive: (@Sendable () -> Bool)?
    private var sourceActiveCached = false
    private var sourceActiveCheckedAt = -Int.max

    init(channel: AudioChannel, directory: URL, mixdown: Mixdown, callbacks: Callbacks) throws(AudioCaptureError) {
        self.channel = channel
        self.mixdown = mixdown
        self.callbacks = callbacks
        fileURL = directory.appendingPathComponent(CaptureFiles.fileName(for: channel))
        queue = DispatchQueue(label: "com.lapcat.audio.pipeline.\(channel.rawValue)", qos: .userInitiated)
        do {
            file = try AVAudioFile(
                forWriting: fileURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 48_000,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw .fileWrite("\(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Called from audio threads with an owned buffer; only enqueues.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        // Ownership moves to the queue: sources hand over fresh copies and never touch them again.
        nonisolated(unsafe) let buffer = buffer
        queue.async { self.process(buffer) }
    }

    /// Enables the silent-tap check; `sourceActive` is polled at most once per second of audio.
    func monitorHealth(sourceActive: @escaping @Sendable () -> Bool) {
        queue.async {
            self.health = TapHealthMonitor()
            self.sourceActive = sourceActive
            self.sourceActiveCheckedAt = -Int.max
        }
    }

    /// A new source feeds this pipeline (tap rebuilt, fallback engaged, mic restarted).
    func sourceChanged() {
        queue.async {
            self.signalSeen = false
            self.health?.reset()
            self.resampler = nil
            self.normalizer = nil
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { self.paused = paused }
    }

    /// Appends silence when the channel lags the session clock by more than 500 ms (source
    /// rebuilt, device restarted), keeping both channels on one timeline.
    func padSilence(upTo targetSamples: Int) {
        queue.async {
            guard !self.paused, !self.finished else { return }
            let lag = targetSamples - (self.delivered + self.pending.count)
            guard lag > Self.sampleRate / 2 else { return }
            self.pending.append(contentsOf: repeatElement(0, count: lag))
            self.emitFullChunks()
        }
    }

    /// Emits the remainder and closes the file. Returns the channel duration in samples.
    func finish() -> Int {
        queue.sync {
            guard !finished else { return delivered }
            finished = true
            if !pending.isEmpty { emit(pending) }
            pending = []
            if #available(macOS 15.0, *) { file?.close() }
            file = nil
            return delivered
        }
    }

    // MARK: - Queue-confined processing

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard !paused, !finished, buffer.frameLength > 0 else { return }
        guard let mono = monoSamples(buffer), let samples = resample(mono, rate: buffer.format.sampleRate),
            !samples.isEmpty
        else { return }

        if !signalSeen, samples.contains(where: { $0 != 0 }) {
            signalSeen = true
            callbacks.signal()
        }
        if var health, let sourceActive {
            let second = delivered / Self.sampleRate
            if second != sourceActiveCheckedAt {
                sourceActiveCheckedAt = second
                sourceActiveCached = sourceActive()
            }
            if health.observe(samples, sourceActive: sourceActiveCached) { callbacks.silentWhileActive() }
            self.health = health
        }
        pending.append(contentsOf: samples)
        emitFullChunks()
    }

    private func emitFullChunks() {
        while pending.count >= Self.chunkSamples {
            emit(Array(pending.prefix(Self.chunkSamples)))
            pending.removeFirst(Self.chunkSamples)
        }
    }

    private func emit(_ samples: [Float]) {
        let tStartMs = delivered * 1000 / Self.sampleRate
        delivered += samples.count
        write(samples)
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        callbacks.level(samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot())
        callbacks.chunk(AudioChunk(channel: channel, samples: samples, tStartMs: tStartMs))
    }

    private func write(_ samples: [Float]) {
        guard let file, !writeFailed,
            let buffer = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        do { try file.write(from: buffer) } catch {
            writeFailed = true
            Self.logger.error("\(self.channel.rawValue) write failed: \(error, privacy: .public)")
            callbacks.error(.fileWrite("\(fileURL.lastPathComponent): \(error.localizedDescription)"))
        }
    }

    /// Float32 mono at the source rate.
    private func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        var input = buffer
        if buffer.format.commonFormat != .pcmFormatFloat32 || buffer.format.isInterleaved {
            guard
                let target = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                    channels: buffer.format.channelCount, interleaved: false
                )
            else { return nil }
            if normalizer?.inputFormat != buffer.format {
                normalizer = AVAudioConverter(from: buffer.format, to: target)
            }
            guard let normalizer,
                let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength),
                (try? normalizer.convert(to: converted, from: buffer)) != nil
            else { return nil }
            input = converted
        }
        guard let data = input.floatChannelData else { return nil }
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        if mixdown == .firstChannel || channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let source = data[channel]
            for frame in 0..<frames { mono[frame] += source[frame] }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames { mono[frame] *= scale }
        return mono
    }

    private func resample(_ mono: [Float], rate: Double) -> [Float]? {
        if rate == Double(Self.sampleRate) { return mono }
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(mono.count))
        else { return nil }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        if resampler?.inputFormat != inputFormat {
            resampler = AVAudioConverter(from: inputFormat, to: Self.outputFormat)
        }
        guard let resampler else { return nil }
        let capacity = AVAudioFrameCount(Double(mono.count) * Double(Self.sampleRate) / rate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return nil }
        // The input block runs synchronously inside `convert`, on this queue.
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let source = input
        var error: NSError?
        let status = resampler.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error else {
            Self.logger.error("resample failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
