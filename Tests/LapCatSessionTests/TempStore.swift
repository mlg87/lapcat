import Foundation
import LapCatCore

/// A store on a fresh temp database, and that database's directory.
func makeTempStore() throws -> (Store, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lapcat-tests-\(UUID().uuidString)")
    return (try Store(databaseURL: dir.appendingPathComponent("lapcat.sqlite")), dir)
}

/// A fresh defaults suite that deletes itself, plist included, when the owning test instance goes
/// away; settings never touch `UserDefaults.standard`. `removePersistentDomain` alone leaves an
/// empty plist in ~/Library/Preferences.
final class DefaultsSandbox: @unchecked Sendable {
    let name = "lapcat.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    @MainActor func settings() -> AppSettings { AppSettings(defaults: defaults) }
}
