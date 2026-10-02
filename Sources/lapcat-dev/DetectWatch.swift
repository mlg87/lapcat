import Foundation
import LapCatAudio
import LapCatCore

/// `lapcat-dev detect-watch [bundle-id…|*]`: prints debounced `InputActivity` events from
/// `AudioInputActivityMonitor` until SIGINT. No arguments = the default detection list;
/// `*` watches every process (bare executables too).
enum DetectWatch {
    static func run(_ arguments: [String]) async -> Int32 {
        let bundleIDs = arguments.isEmpty ? AppSettings.Default.detectBundleIDs : arguments
        print("watching: \(bundleIDs.joined(separator: ", ")) (Ctrl-C to stop)")
        let monitor = AudioInputActivityMonitor(bundleIDs: bundleIDs)

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { monitor.stop() }
        sigint.resume()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
        formatter.timeZone = .current
        monitor.start()
        for await activity in monitor.activities {
            let state = activity.isRunningInput ? "INPUT ON " : "INPUT OFF"
            let process = activity.processBundleID ?? "-"
            print("\(formatter.string(from: Date())) \(state) \(activity.bundleID) pid=\(activity.pid) name=\(activity.name) process=\(process)")
        }
        sigint.cancel()
        return 0
    }
}
