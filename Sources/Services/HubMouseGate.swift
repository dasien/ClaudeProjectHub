import AppKit
import CoreGraphics
import Foundation

/// Toggles `NSWindow.ignoresMouseEvents` on the hub window based on
/// where the cursor is. When the cursor is over the dock area, the
/// hub becomes click-through so events fall through to the docked
/// foreign window underneath. When the cursor is over the chrome
/// (sidebar, tab bar, titlebar), the hub stays interactive.
///
/// `NSView.hitTest` returning nil isn't sufficient for cross-window
/// click-through — AppKit doesn't auto-forward unclaimed clicks to
/// the next window. `ignoresMouseEvents` is the property that makes
/// the OS treat the window as transparent to clicks.
///
/// Two NSEvent monitors are needed:
///   - **Local** for cursor moves while the window is interactive
///     (so we can detect when the cursor enters the dock area).
///   - **Global** for cursor moves while the window is ignoring
///     events (so we can detect when the cursor leaves the dock
///     area — local monitors don't fire when ignoresMouseEvents is
///     true because the events go to whichever window is below).
@MainActor
final class HubMouseGate {
    private weak var window: NSWindow?
    /// Dock rect in AppKit screen coords (bottom-left origin, Y up).
    /// Translated from the CG/AX rect we get elsewhere.
    private var dockRectAppKit: CGRect = .zero
    /// Disabled when nothing is docked — the dock area should claim
    /// clicks normally then, so they don't leak through to the
    /// desktop.
    private var enabled: Bool = false

    private var globalMonitor: Any?
    private var localMonitor: Any?

    func attach(to window: NSWindow) {
        self.window = window
        startMonitoring()
        evaluate()
    }

    /// Update the gate's view of where the dock area is and whether
    /// click-through should be active. Called by DockController on
    /// every dockRect/dock/undock change.
    func setRect(_ cgRect: CGRect, enabled: Bool) {
        self.dockRectAppKit = HubMouseGate.appKitRect(from: cgRect)
        self.enabled = enabled
        evaluate()
    }

    private func startMonitoring() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.evaluate() }
            return event
        }
    }

    private func evaluate() {
        guard let window else { return }
        if !enabled || dockRectAppKit.isEmpty {
            if window.ignoresMouseEvents { window.ignoresMouseEvents = false }
            return
        }
        let cursor = NSEvent.mouseLocation
        let shouldIgnore = dockRectAppKit.contains(cursor)
        if window.ignoresMouseEvents != shouldIgnore {
            window.ignoresMouseEvents = shouldIgnore
        }
    }

    /// Convert from CG/AX (top-left origin, Y down) to AppKit screen
    /// coords (bottom-left origin from primary display, Y up). Same
    /// as `flippedToAXScreen` in reverse.
    private static func appKitRect(from cg: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        let primaryHeight = primary.frame.height
        return CGRect(
            x: cg.origin.x,
            y: primaryHeight - cg.maxY,
            width: cg.width,
            height: cg.height
        )
    }

    deinit {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
    }
}
