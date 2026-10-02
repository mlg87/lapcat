import LapCatCore
import LapCatSpeech
import Observation
import SwiftUI

/// Catalog model downloads started from Settings. App-wide so a download keeps running and
/// reporting progress while the user switches tabs or closes the Settings window.
@Observable @MainActor
final class ModelDownloads {
    static let shared = ModelDownloads()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case failed(String)
        case available
    }

    private var active: [String: Double] = [:]
    private var failures: [String: String] = [:]
    /// Bumped when a download finishes so `state(of:)` re-reads the file system.
    private var generation = 0
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    private var modelsDirectory: URL { Paths.standard.models }

    func state(of id: String) -> State {
        _ = generation
        if let fraction = active[id] { return .downloading(fraction) }
        if FileManager.default.fileExists(atPath: modelsDirectory.appending(path: id).path) { return .available }
        if let failure = failures[id] { return .failed(failure) }
        return .missing
    }

    func start(_ id: String, offlineOnly: Bool) {
        guard tasks[id] == nil else { return }
        failures[id] = nil
        active[id] = 0
        let downloader = ModelDownloader(modelsDirectory: modelsDirectory, offlineOnly: offlineOnly)
        // `self` is the app-lifetime singleton; strong captures are fine.
        tasks[id] = Task { [self] in
            do {
                try await downloader.download(id) { fraction in
                    Task { @MainActor in self.report(fraction, for: id) }
                }
            } catch {
                // Cancel surfaces as URLError.cancelled; the `.partial` file is kept for resume.
                if !Task.isCancelled {
                    failures[id] = (error as? ModelError)?.description ?? error.localizedDescription
                }
            }
            finish(id)
        }
    }

    private func report(_ fraction: Double, for id: String) {
        guard let shown = active[id], fraction - shown >= 0.002 || fraction >= 1 else { return }
        active[id] = fraction
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    /// Re-reads the models folder (files may have been added or removed outside LapCat).
    func refresh() {
        generation += 1
    }

    private func finish(_ id: String) {
        tasks[id] = nil
        active[id] = nil
        generation += 1
    }
}

/// One catalog model: name, size, and a Download button / progress bar / "Downloaded" mark.
struct ModelDownloadRow: View {
    let entry: ModelEntry
    @Environment(AppState.self) private var appState
    private var downloads: ModelDownloads { .shared }

    var body: some View {
        let offline = appState.settings.llmOfflineOnly
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.displayName)
                    Text("\(entry.fileName) · \(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch downloads.state(of: entry.id) {
                case .available:
                    Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 120)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().frame(width: 40)
                    Button("Cancel") { downloads.cancel(entry.id) }
                case .missing, .failed:
                    Button("Download") { downloads.start(entry.id, offlineOnly: offline) }
                        .disabled(offline)
                }
            }
            if case .failed(let reason) = downloads.state(of: entry.id) {
                Text(reason).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// Shown under model lists while downloads are blocked.
struct OfflineDownloadNote: View {
    var body: some View {
        Label("Offline-only mode is on (Settings → AI), so model downloads are disabled.", systemImage: "wifi.slash")
            .font(.caption).foregroundStyle(.secondary)
    }
}
