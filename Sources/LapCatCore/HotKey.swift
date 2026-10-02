import Foundation

/// A global shortcut: a virtual key code plus Carbon modifier flags
/// (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
public struct HotKey: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Carbon modifier bits (HIToolbox/Events.h), duplicated so this model has no Carbon dependency.
    public static let cmd: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    /// Human-readable form such as `⌃⌥N`.
    public var displayString: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "#\(keyCode)")
    }

    /// ANSI virtual key codes (HIToolbox/Events.h `kVK_ANSI_*`) for letters and digits.
    static let keyNames: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z", 0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x31: "Space",
    ]
}

public enum HotKeyAction: String, CaseIterable, Sendable, Identifiable {
    case newNote, end, pauseResume, open

    public var id: String { rawValue }
    public var defaultsKey: String { "hotkey.\(rawValue)" }

    public var displayName: String {
        switch self {
        case .newNote: "New Note / Start"
        case .end: "End"
        case .pauseResume: "Pause / Resume"
        case .open: "Open LapCat"
        }
    }

    public var defaultHotKey: HotKey {
        let mods = HotKey.control | HotKey.option
        return switch self {
        case .newNote: HotKey(keyCode: 0x2D, modifiers: mods)     // ⌃⌥N
        case .end: HotKey(keyCode: 0x0E, modifiers: mods)         // ⌃⌥E
        case .pauseResume: HotKey(keyCode: 0x23, modifiers: mods) // ⌃⌥P
        case .open: HotKey(keyCode: 0x25, modifiers: mods)        // ⌃⌥L
        }
    }
}

/// The four bindings, persisted as JSON in `UserDefaults` under `hotkey.<action>`.
public struct HotKeyBindings: Equatable, Sendable {
    public private(set) var keys: [HotKeyAction: HotKey]

    public init(keys: [HotKeyAction: HotKey]) { self.keys = keys }

    public static func load(from defaults: UserDefaults = .standard) -> HotKeyBindings {
        var keys: [HotKeyAction: HotKey] = [:]
        for action in HotKeyAction.allCases {
            if let data = defaults.data(forKey: action.defaultsKey),
               let key = try? JSONDecoder().decode(HotKey.self, from: data) {
                keys[action] = key
            } else {
                keys[action] = action.defaultHotKey
            }
        }
        return HotKeyBindings(keys: keys)
    }

    public subscript(action: HotKeyAction) -> HotKey { keys[action] ?? action.defaultHotKey }

    /// The other action already bound to `key`, if any.
    public func conflict(for key: HotKey, assigningTo action: HotKeyAction) -> HotKeyAction? {
        HotKeyAction.allCases.first { $0 != action && self[$0] == key }
    }

    public enum AssignError: Error, Equatable { case alreadyUsed(by: HotKeyAction) }

    /// Rebinds `action`; rejects a combination used by another action and leaves state unchanged.
    public mutating func assign(_ key: HotKey, to action: HotKeyAction) throws(AssignError) {
        if let other = conflict(for: key, assigningTo: action) { throw .alreadyUsed(by: other) }
        keys[action] = key
    }

    public func save(to defaults: UserDefaults = .standard) {
        for (action, key) in keys {
            defaults.set(try? JSONEncoder().encode(key), forKey: action.defaultsKey)
        }
    }
}
