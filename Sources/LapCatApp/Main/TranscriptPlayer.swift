import AVFoundation
import LapCatCore
import Observation
import os

/// Plays a meeting's recording from a transcript timestamp: one `AVAudioPlayer` per channel
/// (`mic.aac`, `them.aac`), started together so the two channels are heard mixed.
@Observable @MainActor
final class TranscriptPlayer {
    /// False when the meeting has no audio rows or the files are gone (retention).
    private(set) var isAvailable = false
    private(set) var isPlaying = false
    /// Where the current playback started, for the UI.
    private(set) var startedAtMs: Int?

    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "TranscriptPlayer")

    /// Loads the meeting's existing audio files; call again after audio may have been deleted.
    func load(files: [AudioFile]) {
        stop()
        players = files.compactMap { file in
            let url = URL(fileURLWithPath: file.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                return player
            } catch {
                Self.logger.error("cannot open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        isAvailable = !players.isEmpty
    }

    func play(fromMs ms: Int) {
        guard isAvailable else { return }
        stop()
        let offset = TimeInterval(ms) / 1000
        // Start both channels on the same device tick so they stay aligned.
        let startTime = (players.first?.deviceCurrentTime ?? 0) + 0.1
        for player in players where offset < player.duration {
            player.currentTime = offset
            player.play(atTime: startTime)
        }
        isPlaying = players.contains(where: \.isPlaying)
        startedAtMs = isPlaying ? ms : nil
        let remaining = (players.map(\.duration).max() ?? 0) - offset
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, remaining) + 0.2))
            guard !Task.isCancelled else { return }
            self?.isPlaying = false
            self?.startedAtMs = nil
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        for player in players { player.stop() }
        isPlaying = false
        startedAtMs = nil
    }
}
