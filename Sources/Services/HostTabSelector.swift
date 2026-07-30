import CoreGraphics
import Foundation

/// Switches a host's internal tab to the one matching a given
/// identifier. Needed because some hosts (iTerm2, Terminal) put
/// multiple claude sessions in tabs of the same window — AX raise
/// alone brings the right *window* to front but doesn't pick the
/// right *tab*. So when a hub tab is activated we follow the AX
/// raise with a host-specific AppleScript that selects the
/// matching tab.
///
/// For terminal hosts, the tab identifier is the session's
/// controlling tty (`/dev/ttysNNN`). Hosts without a tabbed model
/// or without an AppleScript story (VSCode, Xcode) are no-ops here.
///
/// **Scoped to the known window** for cost: each AppleScript *property
/// access* is a separate Apple Event, so an unscoped
/// windows→tabs→sessions walk ran ~60-80 of them — measured at ~170ms
/// per tab switch with only three windows open. Both hosts' AppleScript
/// `id of window` IS the CGWindowID (verified empirically 2026-07-30
/// against `CGWindowListCopyWindowInfo` for iTerm2 and Terminal alike),
/// and the dock already caches that id per session, so
/// `window id <cgID>` replaces the outer loop and collapses N windows
/// to 1 — measured ~70ms after.
///
/// **Runs synchronously, deliberately.** Moving it to a background
/// queue removed the remaining ~70ms from the click path but broke tab
/// switching: `AXSupport.raise` is processed asynchronously *inside* the
/// host, so a detached select could land before the host finished
/// handling the raise, after which the host reasserted its own current
/// tab. The visible symptom was the right tab flashing up and then
/// snapping back to the most recently created one. The ordering
/// raise-then-select-to-completion is load-bearing; don't make this
/// async again without moving the raise onto the same queue so the two
/// stay ordered.
enum HostTabSelector {
    /// - Parameter windowID: the session's cached CGWindowID. When nil
    ///   we fall back to walking every window — correct, just slower.
    ///   A *stale* id isn't a problem either: the script errors
    ///   (`-1728`, verified) and the detached runner discards it, which
    ///   is the same outcome as today's "tty not found" case.
    static func selectTab(hostID: String, tabIdentifier: String, windowID: CGWindowID?) {
        switch hostID {
        case "iterm2":
            _ = try? AppleScriptRunner.run(iTerm2Script(tty: tabIdentifier, windowID: windowID))
        case "terminal-app":
            _ = try? AppleScriptRunner.run(terminalScript(tty: tabIdentifier, windowID: windowID))
        default:
            break
        }
    }

    /// iTerm2 nests sessions inside tabs, so the tty lives on the
    /// session and the selection happens on the tab.
    private static func iTerm2Script(tty: String, windowID: CGWindowID?) -> String {
        let body = """
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s is "\(tty)" then
                                tell w to select t
                                return
                            end if
                        end try
                    end repeat
                end repeat
        """
        return wrap(app: "iTerm", windowID: windowID, body: body)
    }

    /// Terminal exposes the tty directly on the tab.
    private static func terminalScript(tty: String, windowID: CGWindowID?) -> String {
        let body = """
                repeat with t in tabs of w
                    try
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            return
                        end if
                    end try
                end repeat
        """
        return wrap(app: "Terminal", windowID: windowID, body: body)
    }

    /// Binds `w` to the target window — directly by id when we have
    /// one, otherwise by iterating — and runs `body` against it. Both
    /// hosts' per-window bodies are identical either way, so the only
    /// difference is how `w` is obtained.
    private static func wrap(app: String, windowID: CGWindowID?, body: String) -> String {
        if let windowID {
            return """
            tell application "\(app)"
                set w to window id \(windowID)
            \(body)
            end tell
            """
        }
        return """
        tell application "\(app)"
            repeat with w in windows
        \(body)
            end repeat
        end tell
        """
    }
}
