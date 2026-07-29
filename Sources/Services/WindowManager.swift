import AppKit
import ApplicationServices

/// Tracks the AX window bound to each session and brings it to the foreground
/// on demand. Window *positioning* (docking into the hub's tab area) was
/// pulled out — it's tracked as a future feature in MEMORY.
@MainActor
final class WindowManager: ObservableObject {
    /// Sessions that currently have a window bound. Published so SwiftUI
    /// can drive off "does this session have a window to show" — the tab
    /// bar uses it, because a tab whose window has been destroyed is a
    /// broken affordance (clicking it can't do anything) even while the
    /// claude process is still alive. Kept in sync via `didSet` on
    /// `bindings` so no mutation site can forget to update it.
    @Published private(set) var boundSessionIDs: Set<Session.ID> = []

    private var bindings: [Session.ID: AXUIElement] = [:] {
        didSet { boundSessionIDs = Set(bindings.keys) }
    }

    func bind(_ window: AXUIElement, to sessionID: Session.ID) {
        bindings[sessionID] = window
    }

    func unbind(_ sessionID: Session.ID) {
        bindings.removeValue(forKey: sessionID)
    }

    func binding(for sessionID: Session.ID) -> AXUIElement? {
        bindings[sessionID]
    }

    func windowID(for sessionID: Session.ID) -> CGWindowID? {
        guard let window = bindings[sessionID] else { return nil }
        return AXSupport.windowID(of: window)
    }

    @discardableResult
    func focus(_ sessionID: Session.ID) -> Bool {
        guard let window = bindings[sessionID] else { return false }
        if let pid = AXSupport.pid(of: window),
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        // raise returns false only when the element is dangling
        // (probe failed). Drop the binding so subsequent focus()
        // calls don't keep waking the dead. The session record's
        // hostWindowID survives for now — a future rediscovery via
        // pid/HostWindowResolver could reattach.
        if AXSupport.raise(window) {
            return true
        }
        bindings.removeValue(forKey: sessionID)
        return false
    }

    /// Best-effort: presses the host window's close button (if AX exposes
    /// one) and removes the binding. The session record itself is updated by
    /// the caller.
    func close(_ sessionID: Session.ID) {
        if let window = bindings[sessionID] {
            AXSupport.pressCloseButton(of: window)
        }
        bindings.removeValue(forKey: sessionID)
    }
}
