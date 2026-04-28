import AppKit
import ApplicationServices

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
        var origin = frame.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        var size = frame.size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
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
