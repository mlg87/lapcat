import Foundation
import LapCatSpeech

/// `lapcat-dev diarize-bench <audio-file>`
///
/// Times FluidAudio diarization model load and diarization separately and prints the speaker turns
/// plus per-speaker totals.
enum DiarizeBench {
    static let usage = "usage: lapcat-dev diarize-bench <audio-file>"

    static func run(_ arguments: [String]) async -> Int32 {
        guard arguments.count == 1, let input = arguments.first else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }
        let url = URL(fileURLWithPath: input)
        do {
            let audioSeconds = Double(try AudioDecoding.decode16kMono(url).count) / 16_000
            let engine = FluidDiarizer()
            print("engine: \(engine.id)")
            print("audio: \(url.lastPathComponent), \(String(format: "%.1f", audioSeconds)) s")

            let loadStart = ContinuousClock.now
            try await engine.load()
            print("load: \(format(loadStart.duration(to: .now))) s")

            let start = ContinuousClock.now
            let turns = try await engine.diarize(fileURL: url)
            let wall = seconds(start.duration(to: .now))
            print(String(
                format: "diarize: wall %.2f s, %.1f s per 10 min of audio, RTF %.2f",
                wall, wall / audioSeconds * 600, audioSeconds / wall
            ))
            var totals: [String: Int] = [:]
            for turn in turns {
                totals[turn.cluster, default: 0] += turn.endMs - turn.startMs
                print(String(format: "[%7.2f – %7.2f] ", Double(turn.startMs) / 1000, Double(turn.endMs) / 1000) + turn.cluster)
            }
            print("\nturns: \(turns.count)")
            for (cluster, ms) in totals.sorted(by: { $0.key < $1.key }) {
                print("  \(cluster): \(String(format: "%.1f", Double(ms) / 1000)) s")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("diarize-bench failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func format(_ duration: Duration) -> String { String(format: "%.2f", seconds(duration)) }
}
