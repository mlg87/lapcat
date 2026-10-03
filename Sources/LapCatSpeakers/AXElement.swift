import ApplicationServices
import Foundation

/// Serial queue every accessibility call runs on. AX calls block on the target app's main thread,
/// so they never run on the caller's executor; each call is capped by the messaging timeout.
public final class AXQueue: Sendable {
    public static let shared = AXQueue()

    private let queue = DispatchQueue(label: "com.lapcat.app.ax", qos: .userInitiated)

    /// - Parameter messagingTimeout: per-call budget in seconds, applied process-wide
    ///   (`AXUIElementSetMessagingTimeout` on the system-wide element).
    public init(messagingTimeout: Float = 0.05) {
        queue.async {
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
        }
    }

    /// Runs `body` on the AX queue.
    public func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// Typed, optional-returning view of an `AXUIElement`. Call its methods on `AXQueue` only.
public struct AXElement: @unchecked Sendable, Hashable {
    public let ref: AXUIElement

    public init(_ ref: AXUIElement) { self.ref = ref }

    public static func application(pid: pid_t) -> AXElement { AXElement(AXUIElementCreateApplication(pid)) }

    /// `AXIsProcessTrusted()`: whether this process holds the Accessibility permission.
    public static var isProcessTrusted: Bool { AXIsProcessTrusted() }

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var title: String? { string(kAXTitleAttribute) }
    public var axDescription: String? { string(kAXDescriptionAttribute) }
    public var identifier: String? { string(kAXIdentifierAttribute) }
    public var help: String? { string(kAXHelpAttribute) }

    /// `AXValue` when it is text (or a number rendered as text).
    public var value: String? {
        guard let raw = attribute(kAXValueAttribute) else { return nil }
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    /// `AXURL` (web areas, links).
    public var url: URL? {
        guard let raw = attribute("AXURL") else { return nil }
        if let url = raw as? URL { return url }
        if let string = raw as? String { return URL(string: string) }
        return nil
    }

    public var frame: CGRect? {
        guard let position: CGPoint = axValue(kAXPositionAttribute, type: .cgPoint, empty: .zero),
            let size: CGSize = axValue(kAXSizeAttribute, type: .cgSize, empty: .zero)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    public var children: [AXElement] { elements(kAXChildrenAttribute) }
    public var windows: [AXElement] { elements(kAXWindowsAttribute) }

    /// `AXWindows` plus window children and the main/focused window, de-duplicated. Some apps (Arc,
    /// windows on another Space) report an empty `AXWindows` while `AXMainWindow` still resolves.
    public var allWindows: [AXElement] {
        var result = windows
        let extra =
            children.filter { $0.role == kAXWindowRole }
            + [element(kAXMainWindowAttribute), element(kAXFocusedWindowAttribute)].compactMap { $0 }
        for window in extra where !result.contains(window) { result.append(window) }
        return result
    }

    /// Descendants (excluding `self`) in depth-first pre-order down to `depth` levels, optionally
    /// keeping only the given roles (filtered elements are still traversed).
    public func children(depth: Int, roleFilter: Set<String>? = nil) -> [AXElement] {
        var result: [AXElement] = []
        func visit(_ element: AXElement, level: Int) {
            guard level < depth else { return }
            for child in element.children {
                if let roleFilter {
                    if let role = child.role, roleFilter.contains(role) { result.append(child) }
                } else {
                    result.append(child)
                }
                visit(child, level: level + 1)
            }
        }
        visit(self, level: 0)
        return result
    }

    /// First descendant (depth-first pre-order, at most `depth` levels) satisfying `predicate`.
    public func firstDescendant(depth: Int = 40, where predicate: (AXElement) -> Bool) -> AXElement? {
        func visit(_ element: AXElement, level: Int) -> AXElement? {
            guard level < depth else { return nil }
            for child in element.children {
                if predicate(child) { return child }
                if let found = visit(child, level: level + 1) { return found }
            }
            return nil
        }
        return visit(self, level: 0)
    }

    /// Makes a Chromium browser (and Electron apps) build its web-content accessibility tree.
    /// Sets both `AXEnhancedUserInterface` (the VoiceOver signal) and `AXManualAccessibility`
    /// (Chromium's own switch); returns whether either was accepted.
    @discardableResult
    public func enableWebAccessibility() -> Bool {
        let enhanced = AXUIElementSetAttributeValue(ref, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let manual = AXUIElementSetAttributeValue(ref, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return enhanced == .success || manual == .success
    }

    /// Snapshot of this element's text attributes, used by selectors and dumps.
    public func snapshot() -> AXNodeSnapshot {
        AXNodeSnapshot(
            role: role,
            subrole: subrole,
            title: title,
            description: axDescription,
            value: value,
            identifier: identifier,
            url: url?.absoluteString,
            frame: frame
        )
    }

    // MARK: - Raw access

    public func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ name: String) -> String? {
        guard let string = attribute(name) as? String, !string.isEmpty else { return nil }
        return string
    }

    private func elements(_ name: String) -> [AXElement] {
        guard let raw = attribute(name), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        return (raw as! [AnyObject]).compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return AXElement(item as! AXUIElement)
        }
    }

    private func element(_ name: String) -> AXElement? {
        guard let raw = attribute(name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXElement(raw as! AXUIElement)
    }

    /// Unpacks a geometry `AXValue`; `T` must be the plain struct matching `type` (CGPoint, CGSize).
    private func axValue<T: BitwiseCopyable>(_ name: String, type: AXValueType, empty: T) -> T? {
        guard let raw = attribute(name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = empty
        guard withUnsafeMutableBytes(of: &result, { AXValueGetValue(raw as! AXValue, type, $0.baseAddress!) }) else {
            return nil
        }
        return result
    }
}

/// Text attributes of one AX element plus its children, detached from the live tree.
public struct AXNodeSnapshot: Sendable, Hashable, Codable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var description: String?
    public var value: String?
    public var identifier: String?
    public var url: String?
    public var frame: CGRect?
    public var children: [AXNodeSnapshot]

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        url: String? = nil,
        frame: CGRect? = nil,
        children: [AXNodeSnapshot] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.value = value
        self.identifier = identifier
        self.url = url
        self.frame = frame
        self.children = children
    }

    /// Captures `element` and its descendants down to `depth` levels, stopping after `maxNodes`.
    public static func capture(_ element: AXElement, depth: Int, maxNodes: Int = 5_000) -> AXNodeSnapshot {
        var budget = maxNodes
        func visit(_ element: AXElement, level: Int) -> AXNodeSnapshot {
            budget -= 1
            var node = element.snapshot()
            guard level < depth else { return node }
            for child in element.children {
                guard budget > 0 else { break }
                node.children.append(visit(child, level: level + 1))
            }
            return node
        }
        return visit(element, level: 0)
    }

    /// Self and all descendants in depth-first pre-order.
    public var flattened: [AXNodeSnapshot] {
        var result: [AXNodeSnapshot] = []
        func visit(_ node: AXNodeSnapshot) {
            result.append(node)
            node.children.forEach(visit)
        }
        visit(self)
        return result
    }
}
