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
/// Implementation: a 30Hz timer polls `NSEvent.mouseLocation` and
/// updates `ignoresMouseEvents` based on whether the cursor is in
/// the dock rect. We tried event-driven updates via NSEvent
/// monitors (`addLocalMonitorForEvents` for mouseMoved) but those
/// only fire when the cursor *moves* — if the user clicks without
/// moving (e.g. after a Cmd-Tab teleport), the gate's state is
/// whatever it was last set to, which led to clicks intermittently
/// passing through the sidebar. Polling guarantees the state is
/// current before any click event is processed.
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
    private var pollTimer: Timer?

    func attach(to window: NSWindow) {
        self.window = window
        startPolling()
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

    private func startPolling() {
        guard pollTimer == nil else { return }
        // 30Hz is plenty for tracking cursor position relative to a
        // window region. NSEvent.mouseLocation is a cheap static
        // query — no IPC, no allocations — so the per-tick cost is
        // negligible.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate()
            }
        }
        // Add to common modes so the timer keeps firing during
        // window resize/drag tracking, modal panels, etc.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
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
        pollTimer?.invalidate()
    }
}
