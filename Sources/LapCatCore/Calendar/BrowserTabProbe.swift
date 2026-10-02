import AppKit
import Foundation

/// Asks a running browser for its front tab's URL via AppleScript (Step 9.3c, Meet detection).
/// Needs the Automation permission for that browser; the first call makes macOS prompt.
public enum BrowserTabProbe {
    /// Browsers with a Chromium-style `active tab of front window` scripting dictionary.
    public static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
    ]
    public static let safariBundleIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    /// The AppleScript source for `bundleID`, nil for browsers without a usable dictionary (Firefox).
    public static func script(for bundleID: String) -> String? {
        if chromiumBundleIDs.contains(bundleID) {
            return "tell application id \"\(bundleID)\" to get URL of active tab of front window"
        }
        if safariBundleIDs.contains(bundleID) {
            return "tell application id \"\(bundleID)\" to get URL of current tab of front window"
        }
        return nil
    }

    /// The front tab URL, or nil when the browser is not running (it is never launched),
    /// unsupported, has no window, Automation is denied, or `osascript` exceeds `timeout`.
    public static func activeURL(bundleID: String, timeout: TimeInterval = 5) async -> URL? {
        guard let source = script(for: bundleID),
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        else { return nil }
        guard let output = await runOSAScript(source, timeout: timeout) else { return nil }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }

    /// Stdout of `osascript -e source` on exit status 0, else nil (error or timeout).
    private static func runOSAScript(_ source: String, timeout: TimeInterval) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            process.terminationHandler = { process in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
                if process.isRunning { process.terminate() }
            }
        }
    }
}
