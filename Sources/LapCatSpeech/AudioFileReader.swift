@preconcurrency import AVFoundation
import os

/// Decodes a whole recording (ADTS `.aac`, CAF, WAV, …) to 16 kHz mono Float32.
public enum AudioDecoding {
    public static func decode16kMono(_ url: URL) throws -> [Float] {
        try AudioFileReader(url: url).readAll()
    }
}

/// Sequentially decodes any AVAudioFile-readable recording (ADTS AAC, CAF, WAV, AIFF) to 16 kHz mono Float32.
/// Not thread-safe: create one per transcription call.
final class AudioFileReader {
    static let sampleRate: Double = 16_000

    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let readBuffer: AVAudioPCMBuffer
    private let targetFormat: AVAudioFormat
    private var finished = false

    /// Estimated length in 16 kHz frames (compressed formats report an estimate).
    let estimatedFrames: Int

    init(url: URL) throws {
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SpeechError.audioDecodeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        else {
            throw SpeechError.audioDecodeFailed("cannot build 16 kHz target format")
        }
        targetFormat = target
        let source = file.processingFormat
        let needsConversion =
            source.sampleRate != Self.sampleRate || source.channelCount != 1
            || source.commonFormat != .pcmFormatFloat32
        if needsConversion {
            guard let conv = AVAudioConverter(from: source, to: target) else {
                throw SpeechError.audioDecodeFailed("no converter from \(source) to 16 kHz mono")
            }
            converter = conv
        } else {
            converter = nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 16_384) else {
            throw SpeechError.audioDecodeFailed("cannot allocate read buffer")
        }
        readBuffer = buffer
        estimatedFrames = Int(Double(file.length) * Self.sampleRate / source.sampleRate)
    }

    /// Reads up to `frames` 16 kHz samples; returns fewer only at end of file (empty = done).
    func read(frames: Int) throws -> [Float] {
        guard !finished, frames > 0 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(frames)
        while out.count < frames, !finished {
            let chunk = try readChunk(maxFrames: frames - out.count)
            if chunk.isEmpty { finished = true } else { out.append(contentsOf: chunk) }
        }
        return out
    }

    func readAll() throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(max(estimatedFrames, 0))
        while true {
            let chunk = try read(frames: 16_000 * 30)
            if chunk.isEmpty { return out }
            out.append(contentsOf: chunk)
        }
    }

    private func readChunk(maxFrames: Int) throws -> [Float] {
        let capacity = AVAudioFrameCount(min(maxFrames, 16_384))
        guard let converter else {
            // AVAudioFile throws (nilError) instead of returning 0 frames when reading at the end.
            guard file.framePosition < file.length else { return [] }
            do {
                try file.read(into: readBuffer, frameCount: capacity)
            } catch {
                throw SpeechError.audioDecodeFailed(error.localizedDescription)
            }
            return Self.samples(readBuffer)
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw SpeechError.audioDecodeFailed("cannot allocate output buffer")
        }
        // The input block is @Sendable; it runs synchronously inside convert(), the lock only satisfies the type.
        let readError = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
        var conversionError: NSError?
        let file = self.file
        let readBuffer = self.readBuffer
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard file.framePosition < file.length else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: readBuffer)
            } catch {
                readError.withLock { $0 = error }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if readBuffer.frameLength == 0 {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return readBuffer
        }
        if let readError = readError.withLock({ $0 }) {
            throw SpeechError.audioDecodeFailed(readError.localizedDescription)
        }
        if status == .error {
            throw SpeechError.audioDecodeFailed(conversionError?.localizedDescription ?? "conversion error")
        }
        let samples = Self.samples(output)
        if status == .endOfStream && samples.isEmpty { return [] }
        return samples
    }

    private static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
