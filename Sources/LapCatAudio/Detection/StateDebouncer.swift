import Foundation

/// Per-key change debouncer with injected time: a new value is emitted only after it has held
/// for `interval`; a flap back to the last emitted value inside the interval emits nothing.
/// Every key starts from `baseline` (never emitted itself).
struct StateDebouncer<Key: Hashable, Value: Equatable> {
    let interval: TimeInterval
    let baseline: Value
    private var emitted: [Key: Value] = [:]
    private var pending: [Key: (value: Value, since: Date)] = [:]

    init(interval: TimeInterval, baseline: Value) {
        self.interval = interval
        self.baseline = baseline
    }

    /// Records the current raw value of `key` at `now`.
    mutating func observe(_ key: Key, _ value: Value, now: Date) {
        if value == emitted[key, default: baseline] {
            pending[key] = nil
        } else if pending[key]?.value != value {
            pending[key] = (value, now)
        }
    }

    /// Emits (and commits) every pending value that has held for `interval` by `now`.
    mutating func due(now: Date) -> [(key: Key, value: Value)] {
        var out: [(key: Key, value: Value)] = []
        for (key, entry) in pending where now.timeIntervalSince(entry.since) >= interval {
            pending[key] = nil
            emitted[key] = entry.value
            out.append((key, entry.value))
        }
        return out
    }

    /// The earliest moment `due` would emit something; nil when nothing is pending.
    var nextDeadline: Date? {
        pending.values.map { $0.since.addingTimeInterval(interval) }.min()
    }

    /// Last emitted value (or baseline).
    func current(_ key: Key) -> Value { emitted[key, default: baseline] }

    /// Drops all state for `key`.
    mutating func forget(_ key: Key) {
        emitted[key] = nil
        pending[key] = nil
    }

    var hasPending: Bool { !pending.isEmpty }
    func isPending(_ key: Key) -> Bool { pending[key] != nil }
}
