import Foundation
import Testing
@testable import LapCatAudio

struct AutoStopTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func stopsOnlyAfterSixtyContinuousSecondsAndOnce() {
        var tracker = AutoStopTracker()
        #expect(tracker.observe(isRunningInput: true, now: t0) == .keepRecording)
        #expect(tracker.stopDeadline == nil)
        #expect(tracker.observe(isRunningInput: false, now: t0) == .keepRecording)
        #expect(tracker.stopDeadline == t0.addingTimeInterval(60))
        #expect(tracker.observe(isRunningInput: false, now: t0.addingTimeInterval(59.999)) == .keepRecording)
        #expect(tracker.observe(isRunningInput: false, now: t0.addingTimeInterval(60)) == .shouldStop)
        #expect(tracker.observe(isRunningInput: false, now: t0.addingTimeInterval(120)) == .keepRecording)
        #expect(tracker.stopDeadline == nil)
    }

    @Test func inputResumingResetsTheStretch() {
        var tracker = AutoStopTracker()
        _ = tracker.observe(isRunningInput: false, now: t0)
        _ = tracker.observe(isRunningInput: true, now: t0.addingTimeInterval(50))
        #expect(tracker.observe(isRunningInput: false, now: t0.addingTimeInterval(55)) == .keepRecording)
        #expect(tracker.observe(isRunningInput: false, now: t0.addingTimeInterval(114)) == .keepRecording)
        #expect(tracker.observe(isRunningInput: false, now: t0.addingTimeInterval(115)) == .shouldStop)

        // After firing, a new active→inactive stretch can fire again.
        _ = tracker.observe(isRunningInput: true, now: t0.addingTimeInterval(200))
        _ = tracker.observe(isRunningInput: false, now: t0.addingTimeInterval(210))
        #expect(tracker.observe(isRunningInput: false, now: t0.addingTimeInterval(270)) == .shouldStop)
    }
}

struct StateDebouncerTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func emitsOnlyAfterValueHoldsForInterval() {
        var d = StateDebouncer<Int, Bool>(interval: 1.5, baseline: false)
        d.observe(1, true, now: t0)
        #expect(d.nextDeadline == t0.addingTimeInterval(1.5))
        #expect(d.due(now: t0.addingTimeInterval(1.49)).isEmpty)
        // Repeating the same raw value does not restart the clock.
        d.observe(1, true, now: t0.addingTimeInterval(1.0))
        let out = d.due(now: t0.addingTimeInterval(1.5))
        #expect(out.map(\.key) == [1])
        #expect(out.map(\.value) == [true])
        #expect(d.nextDeadline == nil)
        #expect(d.due(now: t0.addingTimeInterval(10)).isEmpty)
    }

    @Test func flapBackInsideIntervalEmitsNothing() {
        var d = StateDebouncer<Int, Bool>(interval: 1.5, baseline: false)
        d.observe(1, true, now: t0)
        d.observe(1, false, now: t0.addingTimeInterval(0.4))  // back to baseline
        #expect(d.nextDeadline == nil)
        #expect(d.due(now: t0.addingTimeInterval(5)).isEmpty)
        #expect(d.current(1) == false)
    }

    @Test func baselineValueIsNeverEmittedAndKeysAreIndependent() {
        var d = StateDebouncer<Int, Bool>(interval: 1.5, baseline: false)
        d.observe(1, false, now: t0)
        d.observe(2, true, now: t0.addingTimeInterval(1))
        #expect(d.due(now: t0.addingTimeInterval(1.5)).isEmpty)
        #expect(d.due(now: t0.addingTimeInterval(2.5)).map(\.key) == [2])

        // Turning off is debounced the same way.
        d.observe(2, false, now: t0.addingTimeInterval(3))
        d.observe(2, true, now: t0.addingTimeInterval(3.5))
        #expect(d.due(now: t0.addingTimeInterval(6)).isEmpty)
        d.observe(2, false, now: t0.addingTimeInterval(7))
        let off = d.due(now: t0.addingTimeInterval(8.5))
        #expect(off.map(\.value) == [false])
    }
}

struct InputActivityMatchingTests {
    @Test func matchesExactOrDottedPrefixCaseInsensitively() {
        let configured = ["us.zoom.xos", "com.google.Chrome", "company.thebrowser.Browser"]
        #expect(AudioInputActivityMonitor.matchedBundleID(processBundleID: "us.zoom.xos", configured: configured) == "us.zoom.xos")
        #expect(AudioInputActivityMonitor.matchedBundleID(processBundleID: "com.google.Chrome.helper", configured: configured) == "com.google.Chrome")
        #expect(AudioInputActivityMonitor.matchedBundleID(processBundleID: "company.thebrowser.browser.helper", configured: configured) == "company.thebrowser.Browser")
        #expect(AudioInputActivityMonitor.matchedBundleID(processBundleID: "com.google.ChromeRemoteDesktop", configured: configured) == nil)
        #expect(AudioInputActivityMonitor.matchedBundleID(processBundleID: nil, configured: configured) == nil)
    }

    @Test func wildcardMatchesEverythingIncludingBareExecutables() {
        #expect(AudioInputActivityMonitor.matchedBundleID(processBundleID: "com.apple.QuickTimePlayerX", configured: ["*"]) == "com.apple.QuickTimePlayerX")
        #expect(AudioInputActivityMonitor.matchedBundleID(processBundleID: nil, configured: ["*"]) == "")
    }
}
