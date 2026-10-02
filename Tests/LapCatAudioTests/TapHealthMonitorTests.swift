import Testing
@testable import LapCatAudio

@Test func healthMonitorFiresAfterTenSilentSecondsOnlyWhileSourceActive() {
    var monitor = TapHealthMonitor()
    let silence = [Float](repeating: 0, count: 1_600)
    var fired = 0
    for _ in 0..<99 where monitor.observe(silence, sourceActive: true) { fired += 1 }
    #expect(fired == 0)
    let crossed = monitor.observe(silence, sourceActive: true)
    let again = monitor.observe(silence, sourceActive: true)
    #expect(crossed)
    #expect(!again)  // once per stretch

    monitor.reset()
    for _ in 0..<200 where monitor.observe(silence, sourceActive: false) { fired += 1 }
    #expect(fired == 0)

    // Any audible sample restarts the count.
    for _ in 0..<99 where monitor.observe(silence, sourceActive: true) { fired += 1 }
    _ = monitor.observe([0.1] + silence.dropFirst(), sourceActive: true)
    for _ in 0..<99 where monitor.observe(silence, sourceActive: true) { fired += 1 }
    #expect(fired == 0)
}
