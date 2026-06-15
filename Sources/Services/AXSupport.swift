import AppKit
import ApplicationServices
import os.log

private let log = Logger(subsystem: "com.bgentry.ClaudeProjectHub", category: "AX")

// Private accessibility function: maps an AXUIElement (window) to its
// CGWindowID. Stable across macOS versions, widely used by window-management
// utilities. NOT a SkyLight API — those govern window compositing/reparenting,
// which we deliberately don't touch.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

enum AXSupport {
    static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let array = value as? [AXUIElement] else { return [] }
        return array
    }

    static func title(of element: AXUIElement) -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        guard err == .success, let title = value as? String else { return nil }
        return title
    }

    static func setFrame(_ frame: CGRect, on element: AXUIElement) {
        setPosition(frame.origin, on: element)
        setSize(frame.size, on: element)
    }

    /// Writes `kAXPositionAttribute` only. Splitting position and size
    /// writes lets callers skip redundant work — e.g. during a hub
    /// drag the size never changes, so writing it 60 times a second
    /// is wasted IPC.
    static func setPosition(_ point: CGPoint, on element: AXUIElement) {
        var p = point
        if let value = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
    }

    /// Writes `kAXSizeAttribute` only.
    static func setSize(_ size: CGSize, on element: AXUIElement) {
        var s = size
        if let value = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    /// Position-only write that records the AX write with a tracker so
    /// the resulting notification can be filtered out as not user-
    /// initiated. Returns the window's CGWindowID for tracker keying.
    static func setPosition(
        _ point: CGPoint,
        on element: AXUIElement,
        windowID: CGWindowID,
        tracker: AXWriteTracker
    ) {
        tracker.recordWrite(window: windowID, attribute: kAXPositionAttribute as String)
        setPosition(point, on: element)
    }

    /// Size-only counterpart to the tracked `setPosition`.
    static func setSize(
        _ size: CGSize,
        on element: AXUIElement,
        windowID: CGWindowID,
        tracker: AXWriteTracker
    ) {
        tracker.recordWrite(window: windowID, attribute: kAXSizeAttribute as String)
        setSize(size, on: element)
    }

    /// `setFrame` variant that records the position/size writes with a
    /// tracker so the corresponding AX notifications can be filtered
    /// out as not-user-initiated. Pass the window's CGWindowID — the
    /// tracker uses it as its key.
    static func setFrame(
        _ frame: CGRect,
        on element: AXUIElement,
        windowID: CGWindowID,
        tracker: AXWriteTracker
    ) {
        setPosition(frame.origin, on: element, windowID: windowID, tracker: tracker)
        setSize(frame.size, on: element, windowID: windowID, tracker: tracker)
    }

    /// Reads the window's current frame from AX. Returns `.zero` if
    /// either attribute is unavailable.
    static func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero

        var posValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
           let pos = posValue {
            AXValueGetValue(pos as! AXValue, .cgPoint, &origin)
        }

        var sizeValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sz = sizeValue {
            AXValueGetValue(sz as! AXValue, .cgSize, &size)
        }

        return CGRect(origin: origin, size: size)
    }

    /// Cheap "is this AX element still backed by a live window" probe.
    /// A single attribute read against `kAXRoleAttribute` — present on
    /// every AX element, so `.success` means the element is responsive
    /// and any other return code means the window has been destroyed
    /// or the host app has gone away. Callers use this (directly or
    /// indirectly via `raise(_:)`'s return value) to drop bindings
    /// that have become dangling, since AX writes against a dangling
    /// element silently no-op and previously left the hub
    /// unresponsive on selection.
    static func elementIsLive(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return err == .success
    }

    /// Brings a window to the front of its app's window stack.
    ///
    /// We set `AXMain` and `AXFocused` before calling `AXRaise` because
    /// JetBrains IDEs (Rider, IntelliJ, etc.) run on JBR and their AX
    /// support is incomplete: `AXRaise` alone makes the window flash
    /// forward for a frame and then JBR's window manager re-asserts its
    /// own idea of which window is main. Marking AXMain first tells JBR
    /// which window we want as primary, so it sticks. Native AppKit apps
    /// either already have these attributes set correctly or accept the
    /// write as a no-op.
    ///
    /// Returns false ONLY when the liveness probe fails — i.e. the
    /// element is dangling and callers should drop their binding. If
    /// the probe passes but individual writes return non-success
    /// (JBR's AX is famously flaky), we log and still return true; on
    /// those hosts the writes routinely report errors yet the raise
    /// itself works, and treating that as failure would cause healthy
    /// bindings to be discarded.
    @discardableResult
    static func raise(_ element: AXUIElement) -> Bool {
        guard elementIsLive(element) else {
            log.error("AXSupport.raise: element is dangling; skipping writes")
            return false
        }
        let mainErr = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focusErr = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let raiseErr = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if mainErr != .success || focusErr != .success || raiseErr != .success {
            log.notice("AXSupport.raise: writes returned non-success (AXMain=\(mainErr.rawValue, privacy: .public) AXFocused=\(focusErr.rawValue, privacy: .public) AXRaise=\(raiseErr.rawValue, privacy: .public)); proceeding")
        }
        return true
    }

    /// Sets `kAXMinimizedAttribute` on a window. `true` minimizes it
    /// to the Dock; `false` restores it (the latter is how DockController
    /// brings a previously-Cmd-M'd session back when the user reselects
    /// it in the hub). Idempotent — writing the current value is a
    /// no-op at the AX layer.
    static func setMinimized(_ minimized: Bool, on element: AXUIElement) {
        AXUIElementSetAttributeValue(
            element,
            kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        let err = AXUIElementGetPid(element, &pid)
        return err == .success ? pid : nil
    }

    /// CGWindowID for an AX window element. For Terminal windows the value
    /// matches Terminal's AppleScript `id` property, so it can be used to
    /// reference the same window across the AX/AppleScript boundary.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        let err = _AXUIElementGetWindow(element, &windowID)
        return err == .success ? windowID : nil
    }

    /// Press a menu item in an app's menu bar by walking a title path.
    /// Example: pressMenuItem(in: terminalPID, path: ["Shell", "New Tab"])
    /// presses the "New Tab" item under the "Shell" menu. Each path
    /// component except the last is a menu (or menu bar item) whose AXMenu
    /// child contains the next component. The final component is pressed
    /// via AXPress. Returns false if any step doesn't resolve.
    @discardableResult
    static func pressMenuItem(in pid: pid_t, path: [String]) -> Bool {
        guard !path.isEmpty else { return false }
        let app = AXUIElementCreateApplication(pid)

        var menuBarValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBarObject = menuBarValue else { return false }
        let menuBar = menuBarObject as! AXUIElement

        var current: AXUIElement = menuBar
        for (index, segment) in path.enumerated() {
            guard let match = child(of: current, withTitle: segment) else { return false }
            if index == path.count - 1 {
                return AXUIElementPerformAction(match, kAXPressAction as CFString) == .success
            }
            // For non-leaf segments, descend into the matched item's submenu
            // (its child AXMenu element).
            guard let submenu = firstChild(of: match) else { return false }
            current = submenu
        }
        return false
    }

    private static func child(of element: AXUIElement, withTitle title: String) -> AXUIElement? {
        children(of: element)?.first { AXSupport.title(of: $0) == title }
    }

    private static func firstChild(of element: AXUIElement) -> AXUIElement? {
        children(of: element)?.first
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard err == .success, let array = value as? [AXUIElement] else { return nil }
        return array
    }

    @discardableResult
    static func pressCloseButton(of window: AXUIElement) -> Bool {
        var closeButton: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            window,
            kAXCloseButtonAttribute as CFString,
            &closeButton
        )
        guard err == .success, let button = closeButton else { return false }
        let pressErr = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        return pressErr == .success
    }

    /// Polls for a window of the given app PID whose title contains the marker.
    /// Returns nil on timeout.
    static func findWindow(
        forMarker marker: String,
        in pid: pid_t,
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.15
    ) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for window in windows(of: pid) {
                if let title = title(of: window), title.contains(marker) {
                    return window
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return nil
    }

    /// Polls for a window of the given app PID whose CGWindowID isn't in the
    /// supplied baseline. Useful for "find the new window after launching"
    /// when the host doesn't expose a custom title we can match on.
    static func waitForNewWindow(
        in pid: pid_t,
        excluding baseline: Set<CGWindowID>,
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.15
    ) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for window in windows(of: pid) {
                if let id = windowID(of: window), !baseline.contains(id) {
                    return window
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return nil
    }

    /// Single-shot variant of `waitForWindow(matching:in:)` — no polling,
    /// returns immediately whether or not the window exists right now.
    /// Use this when probing a persisted CGWindowID at reattach time:
    /// if the window survived the hub restart it's already in the host's
    /// AX window list, and burning the 3s polling timeout when it isn't
    /// would slow the happy path.
    static func findWindow(matching cgID: CGWindowID, in pid: pid_t) -> AXUIElement? {
        for window in windows(of: pid) where windowID(of: window) == cgID {
            return window
        }
        return nil
    }

    /// Polls for a window of the given app PID whose CGWindowID matches the
    /// supplied id. Used when the host has told us the id directly (e.g.
    /// iTerm2's AppleScript returns `id of current window`, which IS the
    /// CGWindowID). Short timeout because this just papers over the small
    /// gap between the AppleScript returning and the window registering
    /// with WindowServer.
    static func waitForWindow(
        matching cgID: CGWindowID,
        in pid: pid_t,
        timeout: TimeInterval = 3.0,
        pollInterval: TimeInterval = 0.1
    ) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for window in windows(of: pid) {
                if windowID(of: window) == cgID {
                    return window
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return nil
    }
}

extension CGRect {
    /// Convert a rect from AppKit screen coordinates (origin bottom-left of
    /// the primary display) to CoreGraphics/AX screen coordinates (origin
    /// top-left of the primary display, y grows downward).
    var flippedToAXScreen: CGRect {
        guard let primary = NSScreen.screens.first else { return self }
        let primaryHeight = primary.frame.height
        return CGRect(
            x: origin.x,
            y: primaryHeight - maxY,
            width: width,
            height: height
        )
    }
}
