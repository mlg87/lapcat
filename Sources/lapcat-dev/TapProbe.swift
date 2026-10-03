import AVFoundation
import Foundation
import LapCatAudio

/// `lapcat-dev tap-probe <bundle-id>|--system <seconds> <out-dir>`: records both channels with
/// `CaptureSession`, then prints source formats, per-second RMS per channel, all-zero seconds and
/// the written files' formats. SIGINT stops early and still closes the files.
enum TapProbe {
    static let usage = "usage: lapcat-dev tap-probe <bundle-id>|--system <seconds> <out-dir> [--voice-processing]"

    private struct SecondStats {
        var sumSquares: Double = 0
        var count = 0
        var nonZero = false
    }

    private struct Stats {
        var seconds: [AudioChannel: [Int: SecondStats]] = [:]

        mutating func add(_ chunk: AudioChunk) {
            let second = chunk.tStartMs / 1000
            var entry = seconds[chunk.channel, default: [:]][second, default: SecondStats()]
            for sample in chunk.samples {
                entry.sumSquares += Double(sample * sample)
                if sample != 0 { entry.nonZero = true }
            }
            entry.count += chunk.samples.count
            seconds[chunk.channel, default: [:]][second] = entry
        }
    }

    static func run(_ arguments: [String]) async -> Int32 {
        let voiceProcessing = arguments.contains("--voice-processing")
        let args = arguments.filter { $0 != "--voice-processing" }
        guard args.count == 3, let seconds = Double(args[1]), seconds > 0 else {
            print(usage)
            return 64
        }
        let directory = URL(fileURLWithPath: args[2], isDirectory: true)
        let scope: TapScope
        if args[0] == "--system" {
            scope = .systemExcludingSelf
            print("scope: system (all processes except lapcat-dev)")
        } else {
            let processes = AudioProcessRegistry.processes()
            guard let resolved = TapScope.forApp(bundleID: args[0], pid: nil, in: processes),
                case .app(let objectIDs, let appPID) = resolved
            else {
                print("no audio process for \(args[0]). Running audio processes:")
                for process in processes {
                    print(
                        "  pid \(process.pid) \(process.bundleID ?? "-") \(process.name) out=\(process.isRunningOutput)"
                    )
                }
                return 1
            }
            scope = resolved
            print("scope: app \(args[0]), main pid \(appPID.map(String.init) ?? "none")")
            for process in processes where objectIDs.contains(process.objectID) {
                print(
                    "  pid \(process.pid) \(process.bundleID ?? "-") \(process.name) object \(process.objectID) output=\(process.isRunningOutput)"
                )
            }
        }

        let session = CaptureSession()
        let eventsTask = Task {
            for await event in session.events { print("event: \(event)") }
        }
        let statsTask = Task {
            var stats = Stats()
            for await chunk in session.chunks { stats.add(chunk) }
            return stats
        }
        do {
            try await session.start(
                scope: scope, directory: directory, micDeviceUID: nil, voiceProcessing: voiceProcessing
            )
        } catch {
            print("start failed: \(error)")
            return 1
        }
        print("recording \(Int(seconds)) s to \(directory.path) (Ctrl-C stops early)")

        signal(SIGINT, SIG_IGN)
        let (stopRequests, stopContinuation) = AsyncStream.makeStream(of: String.self)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signalSource.setEventHandler { stopContinuation.yield("SIGINT") }
        signalSource.resume()
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            stopContinuation.yield("timer")
        }
        var reason = "timer"
        for await request in stopRequests {
            reason = request
            break
        }
        timer.cancel()
        signalSource.cancel()

        let summary = await session.stop()
        let stats = await statsTask.value
        await eventsTask.value
        print(
            "stopped (\(reason)); mic \(format(summary.micDuration)) s, system \(format(summary.systemDuration)) s, fallback \(summary.usedFallback)"
        )

        let mic = stats.seconds[.mic] ?? [:]
        let system = stats.seconds[.system] ?? [:]
        let last = max(mic.keys.max() ?? -1, system.keys.max() ?? -1)
        print("second  mic_rms  system_rms")
        for second in 0...max(last, 0) where last >= 0 {
            print(String(format: "%6d  %7.4f  %10.4f", second, rms(mic[second]), rms(system[second])))
        }
        for channel in AudioChannel.allCases {
            let table = stats.seconds[channel] ?? [:]
            let zero = table.filter { !$0.value.nonZero }.keys.sorted()
            print(
                "\(channel.rawValue) all-zero seconds: \(zero.isEmpty ? "none" : zero.map(String.init).joined(separator: ","))"
            )
        }
        for url in [summary.micFile, summary.systemFile] {
            describeFile(url)
        }
        return 0
    }

    private static func rms(_ stats: SecondStats?) -> Double {
        guard let stats, stats.count > 0 else { return 0 }
        return (stats.sumSquares / Double(stats.count)).squareRoot()
    }

    private static func format(_ seconds: TimeInterval) -> String { String(format: "%.2f", seconds) }

    private static func describeFile(_ url: URL) {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.fileFormat
            let duration = Double(file.length) / format.sampleRate
            let formatID = (format.settings[AVFormatIDKey] as? NSNumber)?.uint32Value ?? 0
            let code = withUnsafeBytes(of: formatID.bigEndian) { String(decoding: $0, as: UTF8.self) }
            print(
                "\(url.lastPathComponent): '\(code)' \(Int(format.sampleRate)) Hz \(format.channelCount) ch, \(Self.format(duration)) s"
            )
        } catch {
            print("\(url.lastPathComponent): unreadable (\(error.localizedDescription))")
        }
    }
}
