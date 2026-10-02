import AppKit
import Foundation
import LapCatSpeakers

/// `lapcat-dev axdump <bundle-id> [--depth 12] [--interval 0.5] [--count N] [--timeout 0.5] [--observe [selectors.json]]`
///
/// Prints the AX tree (role, subrole, title, description, value, identifier, URL, frame) of the app's
/// windows. With an interval it re-dumps until interrupted (or N dumps), prefixing lines that are new
/// since the previous dump with `+` and listing vanished lines with `-`, so the element that changes
/// when someone speaks stands out. Chromium browsers get `AXEnhancedUserInterface` /
/// `AXManualAccessibility` set first so web content is exposed.
///
/// `--observe` instead runs the Zoom/Meet adapter for the bundle id (compiled selectors, or the JSON
/// file given) and prints each `SpeakerObservation`, to check selectors against a live call.
enum AXDump {
    static let usage = "usage: lapcat-dev axdump <bundle-id> [--depth 12] [--interval 0.5] [--count N] [--timeout 0.5] [--observe [selectors.json]]"

    static func run(_ arguments: [String]) async -> Int32 {
        var bundleID: String?
        var depth = 12
        var interval = 0.5
        var count = Int.max
        var timeout: Float = 0.5
        var observe = false
        var selectorsFile: String?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--depth": depth = iterator.next().flatMap(Int.init) ?? depth
            case "--interval": interval = iterator.next().flatMap(Double.init) ?? interval
            case "--count": count = iterator.next().flatMap(Int.init) ?? count
            case "--timeout": timeout = iterator.next().flatMap(Float.init) ?? timeout
            case "--observe": observe = true
            default:
                if argument.hasSuffix(".json") { selectorsFile = argument } else { bundleID = argument }
            }
        }
        guard let bundleID else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }

        print("AXIsProcessTrusted: \(AXElement.isProcessTrusted)")
        guard AXElement.isProcessTrusted else {
            FileHandle.standardError.write(Data("""
            This process lacks the Accessibility permission. Grant it to the terminal app in
            System Settings → Privacy & Security → Accessibility, then rerun.\n
            """.utf8))
            return 1
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            FileHandle.standardError.write(Data("\(bundleID) is not running\n".utf8))
            return 1
        }
        let pid = app.processIdentifier
        print("app: \(app.localizedName ?? bundleID) pid \(pid)")

        // Larger budget than the adapters' 50 ms: a dump walks far more elements than a poll.
        let queue = AXQueue(messagingTimeout: timeout)
        let web = await queue.run { AXElement.application(pid: pid).enableWebAccessibility() }
        print("web accessibility enabled: \(web)")
        if web { try? await Task.sleep(for: .seconds(1)) } // Chromium builds the web tree asynchronously.

        if observe {
            return await runObserve(bundleID: bundleID, pid: pid, selectorsFile: selectorsFile, interval: interval, count: count, queue: queue)
        }

        var previous: Set<String>?
        var iteration = 0
        while iteration < count {
            iteration += 1
            let start = ContinuousClock.now
            let lines = await queue.run { [depth] in dumpLines(pid: pid, depth: depth) }
            let elapsed = start.duration(to: .now)
            print("\n=== dump \(iteration) · \(lines.count) elements · \(elapsed.formatted(.units(allowed: [.milliseconds]))) ===")
            let current = Set(lines)
            for line in lines {
                let marker = previous.map { $0.contains(line) ? " " : "+" } ?? " "
                print("\(marker) \(line)")
            }
            if let previous {
                for line in previous.subtracting(current).sorted() { print("- \(line)") }
            }
            previous = current
            guard iteration < count else { break }
            try? await Task.sleep(for: .seconds(interval))
        }
        return 0
    }

    private static func runObserve(
        bundleID: String, pid: pid_t, selectorsFile: String?, interval: Double, count: Int, queue: AXQueue
    ) async -> Int32 {
        let json = selectorsFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        if selectorsFile != nil, json == nil {
            FileHandle.standardError.write(Data("cannot read \(selectorsFile!)\n".utf8))
            return 1
        }
        let source: any SpeakerSource
        if ZoomAXAdapter.bundleIDs.contains(bundleID) {
            source = ZoomAXAdapter(selectors: .decode(json: json, fallback: .zoomDefault), queue: queue)
        } else if MeetAXAdapter.bundleIDs.contains(bundleID) {
            source = MeetAXAdapter(selectors: .decode(json: json, fallback: .meetDefault), queue: queue)
        } else {
            FileHandle.standardError.write(Data("no speaker adapter for \(bundleID)\n".utf8))
            return 1
        }
        var seen = 0
        for await observation in source.observe(pid: pid, interval: interval) {
            seen += 1
            print("[\(seen)] active=\(observation.activeNames) participants=\(observation.participants) self=\(observation.selfName ?? "-")")
            if seen >= count { break }
        }
        return 0
    }

    private static func dumpLines(pid: pid_t, depth: Int) -> [String] {
        var lines: [String] = []
        for (index, window) in AXElement.application(pid: pid).allWindows.enumerated() {
            let tree = AXNodeSnapshot.capture(window, depth: depth, maxNodes: 20_000)
            func visit(_ node: AXNodeSnapshot, path: String, level: Int) {
                lines.append(String(repeating: "  ", count: level) + "\(path) " + describe(node))
                for (childIndex, child) in node.children.enumerated() {
                    visit(child, path: "\(path).\(childIndex)", level: level + 1)
                }
            }
            visit(tree, path: "w\(index)", level: 0)
        }
        return lines
    }

    private static func describe(_ node: AXNodeSnapshot) -> String {
        var parts = [node.role ?? "?"]
        if let subrole = node.subrole { parts.append("(\(subrole))") }
        for (key, value) in [("title", node.title), ("desc", node.description), ("value", node.value), ("id", node.identifier), ("url", node.url)] {
            if let value { parts.append("\(key)=\(quoted(value))") }
        }
        if let frame = node.frame {
            parts.append(String(format: "@%.0f,%.0f %.0fx%.0f", frame.minX, frame.minY, frame.width, frame.height))
        }
        return parts.joined(separator: " ")
    }

    private static func quoted(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return "\"" + (flat.count > 120 ? String(flat.prefix(120)) + "…" : flat) + "\""
    }
}
