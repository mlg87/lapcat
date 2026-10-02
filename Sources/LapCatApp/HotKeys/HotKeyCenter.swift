import Carbon.HIToolbox
import LapCatCore
import os

/// Registers system-wide hotkeys with Carbon `RegisterEventHotKey`.
///
/// SwiftUI shortcut-recorder packages need the SwiftUIMacros plugin, which the
/// Command Line Tools toolchain does not ship, so this is done by hand.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private let log = Logger(subsystem: "com.lapcat.app", category: "HotKeyCenter")
    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlers: [HotKeyAction: @MainActor () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4C_43_41_54 // 'LCAT'

    private init() {}

    func setHandler(for action: HotKeyAction, _ handler: @escaping @MainActor () -> Void) {
        handlers[action] = handler
    }

    /// (Re)registers every binding; call after the bindings change.
    func register(_ bindings: HotKeyBindings) {
        installEventHandlerIfNeeded()
        unregisterAll()
        for (index, action) in HotKeyAction.allCases.enumerated() {
            let key = bindings[action]
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                log.error("RegisterEventHotKey failed for \(action.rawValue, privacy: .public): \(status)")
            }
        }
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    fileprivate func fire(index: UInt32) {
        let actions = HotKeyAction.allCases
        guard Int(index) < actions.count else { return }
        log.debug("hotkey \(actions[Int(index)].rawValue, privacy: .public)")
        handlers[actions[Int(index)]]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr, id.signature == HotKeyCenter.signature else { return status }
            let index = id.id
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(index: index) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
        if status != noErr { log.error("InstallEventHandler failed: \(status)") }
    }
}
