import CoreAudio
import Foundation
import os

/// A watched process started or stopped using audio input (debounced).
public struct InputActivity: Sendable, Equatable {
    /// The configured bundle id that matched (`com.google.Chrome` for its helper process);
    /// for the `*` wildcard, the process's own bundle id or "" when it has none.
    public var bundleID: String
    /// The process's own bundle id (`com.google.Chrome.helper`), nil for bare executables.
    public var processBundleID: String?
    public var pid: pid_t
    public var name: String
    public var isRunningInput: Bool

    public init(bundleID: String, processBundleID: String?, pid: pid_t, name: String, isRunningInput: Bool) {
        self.bundleID = bundleID
        self.processBundleID = processBundleID
        self.pid = pid
        self.name = name
        self.isRunningInput = isRunningInput
    }
}

/// Detects meeting apps taking the microphone (Step 9.2) with Core Audio property listeners only
/// (no polling): one on the system object's process list, and one per process whose bundle id
/// matches. The HAL does not notify `kAudioProcessPropertyIsRunningInput` itself (observed on
/// macOS 15.7: only `kAudioProcessPropertyDevices` fires when input IO starts/stops), so the
/// per-process listener takes every property change and re-reads `IsRunningInput`.
/// A change is emitted after it holds for `debounce` (1.5 s), so brief device probes never
/// surface. Processes already using input when `start()` runs are reported too; a watched
/// process that exits while using input yields an `isRunningInput: false`.
public final class AudioInputActivityMonitor: @unchecked Sendable {
    public let activities: AsyncStream<InputActivity>

    private struct Tracked {
        var activity: InputActivity
        var listener: AudioObjectPropertyListenerBlock?
        /// Left the process list (or stopped matching); kept until its `true` is retracted.
        var gone = false
    }

    private static let logger = Logger(subsystem: "com.lapcat.app", category: "AudioInputActivityMonitor")

    // All mutable state below is confined to `queue`.
    private let queue = DispatchQueue(label: "com.lapcat.app.input-activity", qos: .utility)
    private let continuation: AsyncStream<InputActivity>.Continuation
    private var bundleIDs: [String]
    private var debouncer: StateDebouncer<AudioObjectID, Bool>
    private var tracked: [AudioObjectID: Tracked] = [:]
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var flushWork: DispatchWorkItem?
    private var running = false
    private var finished = false

    /// `bundleIDs` match a process's bundle id exactly or as a dotted prefix (case-insensitive);
    /// `"*"` matches every process.
    public init(bundleIDs: [String], debounce: TimeInterval = 1.5) {
        self.bundleIDs = bundleIDs
        debouncer = StateDebouncer(interval: debounce, baseline: false)
        (activities, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        // Listeners capture `self` weakly; removing them needs the stored blocks.
        let tracked = self.tracked
        let listListener = processListListener
        for (id, entry) in tracked {
            if let listener = entry.listener { removeListener(id, Self.anyProcessProperty, listener) }
        }
        if let listListener {
            removeListener(CoreAudioProperty.system, Self.processList, listListener)
        }
        continuation.finish()
    }

    /// Installs the listeners and reports processes already using input. Idempotent.
    public func start() {
        queue.async { [self] in
            guard !running, !finished else { return }
            running = true
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshProcesses() }
            let status = addListener(CoreAudioProperty.system, Self.processList, listener)
            if status == noErr {
                processListListener = listener
            } else {
                Self.logger.error("process list listener failed: \(status.fourCC, privacy: .public)")
            }
            refreshProcesses()
        }
    }

    /// Removes every listener and finishes `activities`.
    public func stop() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            running = false
            for id in Array(tracked.keys) { untrack(id) }
            if let listener = processListListener {
                removeListener(CoreAudioProperty.system, Self.processList, listener)
                processListListener = nil
            }
            flushWork?.cancel()
            continuation.finish()
        }
    }

    /// Replaces the watched bundle ids (Settings → Detection). Processes that no longer match
    /// are dropped; if one was reported as using input, its `isRunningInput: false` is emitted.
    public func setBundleIDs(_ bundleIDs: [String]) {
        queue.async { [self] in
            self.bundleIDs = bundleIDs
            guard running else { return }
            for (id, entry) in tracked
            where !entry.gone
                && Self.matchedBundleID(processBundleID: entry.activity.processBundleID, configured: bundleIDs) == nil
            {
                processGone(id)
            }
            refreshProcesses()
        }
    }

    /// The configured id that `processBundleID` matches: equal, or a dotted prefix
    /// (`com.google.Chrome` ⇐ `com.google.Chrome.helper`), case-insensitive; `*` matches all.
    static func matchedBundleID(processBundleID: String?, configured: [String]) -> String? {
        let own = processBundleID?.lowercased()
        for candidate in configured {
            if candidate == "*" { return processBundleID ?? "" }
            guard let own else { continue }
            let wanted = candidate.lowercased()
            if own == wanted || own.hasPrefix(wanted + ".") { return candidate }
        }
        return nil
    }

    // MARK: - Queue-confined

    private func refreshProcesses() {
        guard running else { return }
        let ownPID = getpid()
        let current = Set(
            CoreAudioProperty.objectList(CoreAudioProperty.system, kAudioHardwarePropertyProcessObjectList))
        let now = Date()

        for (id, entry) in tracked where !entry.gone && !current.contains(id) {
            processGone(id)
        }
        // A gone entry still in the list (bundle ids changed back) is skipped until retracted.
        for id in current where tracked[id] == nil {
            guard let info = AudioProcessRegistry.info(forObjectID: id), info.pid != ownPID,
                let matched = Self.matchedBundleID(processBundleID: info.bundleID, configured: bundleIDs)
            else { continue }
            let activity = InputActivity(
                bundleID: matched, processBundleID: info.bundleID, pid: info.pid, name: info.name,
                isRunningInput: info.isRunningInput)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.inputChanged(id) }
            let status = addListener(id, Self.anyProcessProperty, listener)
            if status != noErr {
                Self.logger.error(
                    "input listener for \(info.name, privacy: .public) failed: \(status.fourCC, privacy: .public)")
            }
            tracked[id] = Tracked(activity: activity, listener: status == noErr ? listener : nil)
            // Re-read after installing the listener so a flip in between is not lost.
            debouncer.observe(id, CoreAudioProperty.bool(id, kAudioProcessPropertyIsRunningInput), now: now)
        }
        flushDue()
    }

    private func inputChanged(_ id: AudioObjectID) {
        guard running, let entry = tracked[id], !entry.gone else { return }
        debouncer.observe(id, CoreAudioProperty.bool(id, kAudioProcessPropertyIsRunningInput), now: Date())
        flushDue()
    }

    /// Stops listening to `id`; it stays tracked until a reported `true` is retracted.
    private func processGone(_ id: AudioObjectID) {
        guard let entry = tracked[id] else { return }
        if let listener = entry.listener { removeListener(id, Self.anyProcessProperty, listener) }
        tracked[id]?.listener = nil
        tracked[id]?.gone = true
        debouncer.observe(id, false, now: Date())
        forgetIfIdle(id)
    }

    private func untrack(_ id: AudioObjectID) {
        if let listener = tracked[id]?.listener { removeListener(id, Self.anyProcessProperty, listener) }
        tracked[id] = nil
        debouncer.forget(id)
    }

    private func forgetIfIdle(_ id: AudioObjectID) {
        guard tracked[id]?.gone == true, !debouncer.isPending(id), !debouncer.current(id) else { return }
        tracked[id] = nil
        debouncer.forget(id)
    }

    private func flushDue() {
        let now = Date()
        for (id, value) in debouncer.due(now: now) {
            guard var activity = tracked[id]?.activity else { continue }
            activity.isRunningInput = value
            tracked[id]?.activity = activity
            continuation.yield(activity)
            forgetIfIdle(id)
        }
        flushWork?.cancel()
        flushWork = nil
        guard let deadline = debouncer.nextDeadline else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushDue() }
        flushWork = work
        queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSince(now)), execute: work)
    }

    private static let processList = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
    private static let anyProcessProperty = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertySelectorWildcard, mScope: kAudioObjectPropertyScopeWildcard,
        mElement: kAudioObjectPropertyElementWildcard)

    private func addListener(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var address = address
        return AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
    }

    private func removeListener(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
        _ listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
    }
}
