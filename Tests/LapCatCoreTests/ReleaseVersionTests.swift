import Foundation
import Testing

@testable import LapCatCore

@Suite struct ReleaseVersionTests {
    private func release(_ tag: String) -> GitHubRelease {
        GitHubRelease(tag: tag, notesURL: URL(string: "https://github.com/mlg87/lapcat/releases/tag/\(tag)")!)
    }

    @Test func comparesEachComponentNumerically() throws {
        let v0_1_9 = try #require(ReleaseVersion("v0.1.9"))
        #expect(try #require(ReleaseVersion("v0.1.10")) > v0_1_9)
        #expect(try #require(ReleaseVersion("0.2.0")) > #require(ReleaseVersion("0.1.99")))
        #expect(try #require(ReleaseVersion("1.0.0")) > #require(ReleaseVersion("0.99.99")))
        #expect(ReleaseVersion("v0.1.2") == ReleaseVersion("0.1.2"))
    }

    @Test(arguments: ["", "v", "0.1", "0.1.2.3", "v0.1.x", "0.1.-2", "0.1.+2", "0..2", "release-0.1.2"])
    func rejectsMalformedVersions(_ text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func newerReleaseIsOfferedAsAnUpdate() {
        let update = GitHubRelease.update(from: release("v0.1.3"), runningVersion: "0.1.2")
        #expect(update?.tag == "v0.1.3")
    }

    @Test(arguments: ["0.1.3", "0.2.0"])
    func sameOrOlderReleaseIsNoUpdate(_ running: String) {
        #expect(GitHubRelease.update(from: release("v0.1.3"), runningVersion: running) == nil)
    }

    @Test func malformedTagOrVersionIsNoUpdate() {
        #expect(GitHubRelease.update(from: release("nightly"), runningVersion: "0.1.2") == nil)
        #expect(GitHubRelease.update(from: release("v0.1.3"), runningVersion: "dev") == nil)
    }

    @Test func decodesTheLatestReleasePayload() throws {
        let json = """
            {"tag_name": "v0.1.2", "html_url": "https://github.com/mlg87/lapcat/releases/tag/v0.1.2",
             "draft": false, "prerelease": false, "name": "v0.1.2"}
            """
        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        #expect(decoded == release("v0.1.2"))
    }

    @Test func notesURLForTheRunningVersionPointsAtItsTag() {
        #expect(
            GitHubRelease.notesURL(forVersion: "0.1.2").absoluteString
                == "https://github.com/mlg87/lapcat/releases/tag/v0.1.2")
    }
}
