import Foundation
import LapCatCore
import Observation
import os

/// The running version and, when GitHub has a newer published release, that release. Checks at
/// launch and every 6 hours; never touches the network while Offline only is on.
@Observable @MainActor
final class UpdateChecker {
    /// `CFBundleShortVersionString` (`0.1.2`); nil when running outside the app bundle.
    let runningVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    /// The newer release, if the last successful check found one.
    private(set) var update: GitHubRelease?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.lapcat.app", category: "UpdateChecker")
    private static let interval: Duration = .seconds(6 * 3600)

    init(settings: AppSettings) {
        self.settings = settings
    }

    var runningNotesURL: URL? { runningVersion.map(GitHubRelease.notesURL(forVersion:)) }

    func start() {
        guard task == nil, runningVersion != nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func check() async {
        guard let runningVersion, !settings.llmOfflineOnly else { return }
        var request = URLRequest(url: GitHubRelease.latestReleaseAPI, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                Self.logger.error("latest release request returned HTTP \(status)")
                return
            }
            let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
            update = GitHubRelease.update(from: latest, runningVersion: runningVersion)
        } catch {
            Self.logger.error("latest release check failed: \(String(describing: error), privacy: .public)")
        }
    }
}
