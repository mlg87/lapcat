import Foundation

@testable import LapCatCore

/// A store on a fresh temp database, and that database's directory.
func makeTempStore() throws -> (Store, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lapcat-tests-\(UUID().uuidString)")
    return (try Store(databaseURL: dir.appendingPathComponent("lapcat.sqlite")), dir)
}

let utc = TimeZone(identifier: "UTC")!
