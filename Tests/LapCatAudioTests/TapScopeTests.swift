import CoreAudio
import Testing

@testable import LapCatAudio

@Suite struct TapScopeTests {
    private func process(
        _ objectID: AudioObjectID, pid: pid_t, bundleID: String?, output: Bool = false
    ) -> AudioProcessInfo {
        AudioProcessInfo(
            objectID: objectID, pid: pid, bundleID: bundleID, name: bundleID ?? "pid \(pid)",
            isRunningInput: false, isRunningOutput: output)
    }

    /// Core Audio's process list during the failed Meet call in Arc (issue #49): the call plays from the
    /// audio-service helper, and at the start of a recording no Arc process may produce output.
    private var arcSilent: [AudioProcessInfo] {
        [
            process(128, pid: 11771, bundleID: "company.thebrowser.Browser"),
            process(130, pid: 73835, bundleID: "company.thebrowser.browser.helper"),
            process(131, pid: 73836, bundleID: "company.thebrowser.browser.helper"),
            process(140, pid: 10063, bundleID: "com.anthropic.claudefordesktop"),
            process(141, pid: 10434, bundleID: "com.anthropic.claudefordesktop.helper", output: true),
        ]
    }

    @Test func tapsTheMainProcessAndEveryHelperOfTheApp() {
        let scope = TapScope.forApp(bundleID: "company.thebrowser.Browser", pid: 73835, in: arcSilent)
        #expect(scope == .app(objectIDs: [128, 130, 131], appPID: 11771))
    }

    @Test func bundleMatchIsCaseInsensitiveAndNeedsADotBoundary() {
        let processes = arcSilent + [process(150, pid: 500, bundleID: "company.thebrowser.BrowserTools")]
        let scope = TapScope.forApp(bundleID: "COMPANY.THEBROWSER.BROWSER", pid: nil, in: processes)
        #expect(scope == .app(objectIDs: [128, 130, 131], appPID: 11771))
    }

    @Test func detectedPidOutsideTheBundleFamilyIsTappedToo() {
        let processes = arcSilent + [process(160, pid: 900, bundleID: nil)]
        let scope = TapScope.forApp(bundleID: "company.thebrowser.Browser", pid: 900, in: processes)
        #expect(scope == .app(objectIDs: [128, 130, 131, 160], appPID: 11771))
    }

    @Test func appWithoutItsMainProcessHasNoFallbackPid() {
        let helperOnly = [process(130, pid: 73835, bundleID: "company.thebrowser.browser.helper")]
        let scope = TapScope.forApp(bundleID: "company.thebrowser.Browser", pid: 73835, in: helperOnly)
        #expect(scope == .app(objectIDs: [130], appPID: nil))
    }

    @Test func noMatchingProcessYieldsNil() {
        #expect(TapScope.forApp(bundleID: "us.zoom.xos", pid: 4242, in: arcSilent) == nil)
        #expect(TapScope.forApp(bundleID: nil, pid: nil, in: arcSilent) == nil)
    }
}
