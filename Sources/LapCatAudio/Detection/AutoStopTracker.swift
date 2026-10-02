import Foundation

/// Auto-stop rule for prompted sessions (PRD FR-1.3, Step 9.4): stop once the source process
/// has reported `isRunningInput == false` continuously for `timeout` (default 60 s).
///
/// Input events arrive only on change, so the owner also feeds `(false, now)` from a timer
/// scheduled at `stopDeadline`.
public struct AutoStopTracker: Sendable {
    public enum Decision: Sendable, Equatable {
        case keepRecording, shouldStop
    }

    public let timeout: TimeInterval
    /// Start of the current continuous `false` stretch.
    public private(set) var inactiveSince: Date?
    private var fired = false

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    /// When the current inactive stretch reaches `timeout`; nil while input is active or after firing.
    public var stopDeadline: Date? {
        guard !fired, let inactiveSince else { return nil }
        return inactiveSince.addingTimeInterval(timeout)
    }

    /// Returns `.shouldStop` once per inactive stretch, at the first observation ≥ `timeout`
    /// after it began. Any `true` observation resets the stretch.
    public mutating func observe(isRunningInput: Bool, now: Date) -> Decision {
        if isRunningInput {
            inactiveSince = nil
            fired = false
            return .keepRecording
        }
        let since = inactiveSince ?? now
        inactiveSince = since
        guard !fired, now.timeIntervalSince(since) >= timeout else { return .keepRecording }
        fired = true
        return .shouldStop
    }
}
