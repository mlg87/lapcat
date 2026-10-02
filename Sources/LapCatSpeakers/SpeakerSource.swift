import ApplicationServices
import Foundation
import os

/// What a meeting app's UI shows at one instant.
public struct SpeakerObservation: Sendable, Hashable {
    /// Names currently marked as speaking (never the user's own name).
    public var activeNames: [String]
    /// Every participant name visible.
    public var participants: [String]
    /// The user's own name as the app shows it, when visible.
    public var selfName: String?

    public init(activeNames: [String] = [], participants: [String] = [], selfName: String? = nil) {
        self.activeNames = activeNames
        self.participants = participants
        self.selfName = selfName
    }

    public static let empty = SpeakerObservation()
}

public protocol SpeakerSource: Sendable {
    static var bundleIDs: [String] { get }
    /// Polls the app every `interval` seconds (the recorder uses 0.25 s = 4 Hz) until the stream is
    /// cancelled. Never throws: missing elements or permissions yield empty observations.
    func observe(pid: pid_t, interval: TimeInterval) -> AsyncStream<SpeakerObservation>
}

/// Shared polling loop for selector-driven adapters.
struct AXSpeakerPoller: Sendable {
    let name: String
    let selectors: SpeakerSelectors
    let enableWebAccessibility: Bool
    let queue: AXQueue

    private static let logger = Logger(subsystem: "com.lapcat.app", category: "SpeakerSource")
    /// Consecutive empty observations after which one "nothing found" line is logged.
    static let emptyLogAfter: TimeInterval = 30

    func observe(pid: pid_t, interval: TimeInterval) -> AsyncStream<SpeakerObservation> {
        let (stream, continuation) = AsyncStream.makeStream(of: SpeakerObservation.self, bufferingPolicy: .bufferingNewest(8))
        let selectors = selectors
        let enableWeb = enableWebAccessibility
        let queue = queue
        let name = name
        let task = Task {
            if enableWeb {
                _ = await queue.run { AXElement.application(pid: pid).enableWebAccessibility() }
            }
            var emptySince: ContinuousClock.Instant?
            var loggedEmpty = false
            while !Task.isCancelled {
                let observation = await queue.run {
                    selectors.observation(from: Self.roots(pid: pid, selectors: selectors))
                }
                continuation.yield(observation)
                if observation.participants.isEmpty, observation.activeNames.isEmpty {
                    let since = emptySince ?? .now
                    emptySince = since
                    if !loggedEmpty, since.duration(to: .now) >= .seconds(Self.emptyLogAfter) {
                        loggedEmpty = true
                        Self.logger.notice("\(name, privacy: .public): no speaker elements found for \(Int(Self.emptyLogAfter)) s (pid \(pid))")
                    }
                } else {
                    emptySince = nil
                    loggedEmpty = false
                }
                try? await Task.sleep(for: .seconds(interval))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Captured subtrees the selectors apply to: matching web areas if configured and found,
    /// else the windows whose title matches (all windows when no title pattern is set).
    static func roots(pid: pid_t, selectors: SpeakerSelectors) -> [AXNodeSnapshot] {
        let windows = AXElement.application(pid: pid).allWindows
        let titleRegex = selectors.windowTitlePattern.flatMap { try? NSRegularExpression(pattern: $0) }
        if let pattern = selectors.webAreaURLPattern, let urlRegex = try? NSRegularExpression(pattern: pattern) {
            let webAreas = windows.compactMap { window in
                window.firstDescendant(depth: 12) { element in
                    guard element.role == "AXWebArea", let url = element.url?.absoluteString else { return false }
                    return urlRegex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
                }
            }
            if !webAreas.isEmpty {
                return webAreas.map { AXNodeSnapshot.capture($0, depth: selectors.maxDepth) }
            }
            // No matching web area: fall through to title-matched windows only.
            guard titleRegex != nil else { return [] }
        }
        return windows
            .filter { window in
                guard let titleRegex else { return true }
                let title = window.title ?? ""
                return titleRegex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
            }
            .map { AXNodeSnapshot.capture($0, depth: selectors.maxDepth) }
    }
}

/// Zoom desktop client. Selector defaults are unverified until the axdump spike (lc-6bq) records a
/// live call; pass `SpeakerSelectors.decode(json:fallback:)` output to override them.
public struct ZoomAXAdapter: SpeakerSource {
    public static let bundleIDs = ["us.zoom.xos"]

    private let poller: AXSpeakerPoller

    public init(selectors: SpeakerSelectors = .zoomDefault, queue: AXQueue = .shared) {
        poller = AXSpeakerPoller(name: "ZoomAXAdapter", selectors: selectors, enableWebAccessibility: false, queue: queue)
    }

    public func observe(pid: pid_t, interval: TimeInterval) -> AsyncStream<SpeakerObservation> {
        poller.observe(pid: pid, interval: interval)
    }
}

/// Google Meet in a browser: uses the `AXWebArea` whose URL is on meet.google.com, else a window
/// titled "Meet…". Chromium browsers are switched into full web accessibility first. Selector
/// defaults are unverified until the axdump spike (lc-6bq).
public struct MeetAXAdapter: SpeakerSource {
    public static let bundleIDs = [
        "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser", "com.apple.Safari",
    ]

    private let poller: AXSpeakerPoller

    public init(selectors: SpeakerSelectors = .meetDefault, queue: AXQueue = .shared) {
        poller = AXSpeakerPoller(name: "MeetAXAdapter", selectors: selectors, enableWebAccessibility: true, queue: queue)
    }

    public func observe(pid: pid_t, interval: TimeInterval) -> AsyncStream<SpeakerObservation> {
        poller.observe(pid: pid, interval: interval)
    }
}

public enum SpeakerSources {
    /// The adapter type serving `bundleID`, if any.
    public static func adapterType(for bundleID: String) -> (any SpeakerSource.Type)? {
        if ZoomAXAdapter.bundleIDs.contains(bundleID) { return ZoomAXAdapter.self }
        if MeetAXAdapter.bundleIDs.contains(bundleID) { return MeetAXAdapter.self }
        return nil
    }
}
