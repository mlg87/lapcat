import Foundation
import LapCatSpeech
import os

/// `lapcat-dev stt-bench --engine whisper|parakeet [--model <file>] [--version v2|v3] [--live-only|--file-only] <audio-file>`
///
/// Runs the final-pass path (`transcribeFile`) and the live path (15 s chunks through `transcribe`)
/// and prints the real-time factor (audio seconds ÷ wall seconds) of each plus the transcript.
enum STTBench {
    static let usage = """
        usage: lapcat-dev stt-bench --engine whisper|parakeet [--model <file>] [--version v2|v3] [--live-only|--file-only] <audio-file>
          whisper models (default ggml-small.en.bin) are downloaded into ~/Library/Application Support/LapCat/models/ if missing
        """

    static func run(_ arguments: [String]) async -> Int32 {
        var engineName: String?
        var model = "ggml-small.en.bin"
        var version = "v2"
        var runLive = true
        var runFile = true
        var input: String?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--engine": engineName = iterator.next()
            case "--model": model = iterator.next() ?? model
            case "--version": version = iterator.next() ?? version
            case "--live-only": runFile = false
            case "--file-only": runLive = false
            default: input = argument
            }
        }
        guard let engineName, let input, ["whisper", "parakeet"].contains(engineName) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }
        let url = URL(fileURLWithPath: input)

        do {
            let engine: any TranscriptionEngine
            if engineName == "whisper" {
                let modelsDirectory = URL.applicationSupportDirectory.appending(
                    path: "LapCat/models", directoryHint: .isDirectory)
                let downloader = ModelDownloader(modelsDirectory: modelsDirectory, offlineOnly: false)
                if !downloader.isAvailable(model) {
                    print("downloading \(model) → \(modelsDirectory.path)")
                    let reporter = ProgressPrinter()
                    try await downloader.download(model) { reporter.report($0) }
                    print("")
                }
                engine = WhisperCppEngine(modelURL: downloader.fileURL(for: model))
            } else {
                engine = ParakeetEngine(version: version)
            }

            // Decode fully for the duration: ADTS headers only give an estimate.
            let samples = try AudioDecoding.decode16kMono(url)
            let audioSeconds = Double(samples.count) / 16_000
            print("engine: \(engine.id)")
            print("audio: \(url.lastPathComponent), \(String(format: "%.1f", audioSeconds)) s")

            let loadStart = ContinuousClock.now
            try await engine.load()
            print("load: \(format(loadStart.duration(to: .now))) s")

            if runFile {
                let start = ContinuousClock.now
                let segments = try await engine.transcribeFile(url) { _ in }
                let wall = seconds(start.duration(to: .now))
                print(
                    "\n== transcribeFile (final pass): wall \(String(format: "%.2f", wall)) s, RTF \(String(format: "%.2f", audioSeconds / wall))"
                )
                printSegments(segments)
            }

            if runLive {
                let chunk = 15 * 16_000
                var segments: [TranscribedSegment] = []
                var slowest = Double.infinity
                let start = ContinuousClock.now
                for chunkStart in stride(from: 0, to: samples.count, by: chunk) {
                    let slice = Array(samples[chunkStart..<min(chunkStart + chunk, samples.count)])
                    let chunkClock = ContinuousClock.now
                    segments += try await engine.transcribe(slice, offsetMs: chunkStart / 16)
                    let chunkRTF = Double(slice.count) / 16_000 / seconds(chunkClock.duration(to: .now))
                    slowest = min(slowest, chunkRTF)
                }
                let wall = seconds(start.duration(to: .now))
                print(
                    "\n== transcribe (live, 15 s chunks): wall \(String(format: "%.2f", wall)) s, RTF \(String(format: "%.2f", audioSeconds / wall)), slowest chunk RTF \(String(format: "%.2f", slowest))"
                )
                printSegments(segments)
            }
            await engine.unload()
            return 0
        } catch {
            FileHandle.standardError.write(Data("stt-bench failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func printSegments(_ segments: [TranscribedSegment]) {
        for segment in segments {
            print(
                String(format: "[%7.2f – %7.2f] ", Double(segment.tStartMs) / 1000, Double(segment.tEndMs) / 1000)
                    + segment.text)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func format(_ duration: Duration) -> String { String(format: "%.2f", seconds(duration)) }
}

/// Prints whole-percent download progress on one line.
private final class ProgressPrinter: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: -1)

    func report(_ fraction: Double) {
        let percent = Int(fraction * 100)
        let changed = last.withLock { last in
            defer { last = percent }
            return last != percent
        }
        if changed {
            FileHandle.standardError.write(Data("\r  \(percent)%".utf8))
        }
    }
}
