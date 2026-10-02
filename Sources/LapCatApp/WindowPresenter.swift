import AppKit
import SwiftUI

/// Owns LapCat's AppKit-hosted windows.
///
/// SwiftUI `Window` scenes can only be opened through `openWindow`, which needs a live view;
/// a menu-bar-only app has none at launch (the `MenuBarExtra` label does not run `.task`), so
/// onboarding and hotkeys open windows through this presenter instead.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(id: String, title: String, size: NSSize, resizable: Bool, @ViewBuilder content: () -> Content) {
        let window = windows[id] ?? makeWindow(id: id, title: title, size: size, resizable: resizable, content: content)
        updateActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        // An accessory app is inactive when a hotkey or menu click arrives, and
        // makeKeyAndOrderFront only orders front conditionally while inactive.
        window.orderFrontRegardless()
        window.makeKey()
    }

    private func makeWindow<Content: View>(id: String, title: String, size: NSSize, resizable: Bool, content: () -> Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        // Assigning the hosting controller shrinks the window to SwiftUI's initial (near-zero) fitting
        // size; restore the requested size before centering, or the window grows offscreen.
        window.setContentSize(size)
        window.setFrameAutosaveName("LapCat.\(id)")
        if !window.setFrameUsingName("LapCat.\(id)") { window.center() }
        window.delegate = self
        windows[id] = window
        return window
    }

    func close(id: String) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        updateActivationPolicy()
    }

    /// Dock icon and app menu only while a LapCat window is open; menu-bar-only otherwise.
    private func updateActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = windows.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}
