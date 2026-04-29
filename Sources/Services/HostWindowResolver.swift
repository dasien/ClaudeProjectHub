import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Figures out which host (Terminal/iTerm2/…) and which specific
/// host window contains a given claude process. Two strategies:
///
/// 1. **Parent-PID walk** (cheap, generic): claude → shell → host
///    app, looking for a process whose bundle ID matches a host in
///    the registry. Fails when the chain goes through a detached
///    server like `iTermServer` (iTerm2's restorable sessions) or
///    a tmux server.
/// 2. **Controlling-tty match** (host-specific, robust): get
///    claude's `/dev/ttysNNN`, ask each running known terminal via
///    AppleScript which window contains a session with that tty.
///    Returns a specific CGWindowID, not just the host's PID.
///
/// Try (1) first; fall back to (2) for known terminals where (1)
/// gave us nothing.
@MainActor
enum HostWindowResolver {
    struct Match {
        let hostID: String
        let hostAppPID: pid_t
        /// Specific CGWindowID when we located the exact window
        /// (tty-based path); nil when we only know the host app
        /// (parent-walk path) and have to fall back to the focused
        /// window at adopt time.
        let cgWindowID: CGWindowID?
        /// Host-specific identifier for the *tab/session within the
        /// window*. For terminal hosts this is the controlling tty
        /// (`/dev/ttysNNN`). nil from the parent-walk path because
        /// we only know the host app, not which tab. Used by
        /// `HostTabSelector` to switch the host's internal tab when
        /// the user activates a hub tab — without this, two hub
        /// tabs pointing at sibling iTerm2 tabs both AXRaise the
        /// same window and don't switch tabs.
        let tabIdentifier: String?
    }

    static func resolve(claudePID: pid_t, registry: HostRegistry) -> Match? {
        let knownBundleIDs = Set(registry.hosts.compactMap { $0.bundleIdentifier })

        // tty-based lookup first when we have a tty — gives us the
        // exact tab identity, which matters for hosts where multiple
        // claude sessions can share one window (iTerm2 tabs).
        let tty = ProcessTree.controllingTTY(of: claudePID)
        if let tty {
            for host in registry.hosts {
                guard let bundleID = host.bundleIdentifier,
                      let runningApp = NSRunningApplication.runningApplications(
                          withBundleIdentifier: bundleID
                      ).first else { continue }
                if let cgID = ttyWindow(forHost: host, tty: tty) {
                    return Match(
                        hostID: host.id,
                        hostAppPID: runningApp.processIdentifier,
                        cgWindowID: cgID,
                        tabIdentifier: tty
                    )
                }
            }
        }

        // Fall back to parent-PID walk for hosts without an
        // AppleScript-by-tty story (or terminals where the user
        // configured something custom). Returns the host app's PID
        // but no specific window or tab.
        if let hostPID = ProcessTree.findHostAppPID(for: claudePID, knownBundleIDs: knownBundleIDs),
           let app = NSRunningApplication(processIdentifier: hostPID),
           let bundleID = app.bundleIdentifier,
           let host = registry.hosts.first(where: { $0.bundleIdentifier == bundleID }) {
            return Match(
                hostID: host.id,
                hostAppPID: hostPID,
                cgWindowID: nil,
                tabIdentifier: tty
            )
        }
        return nil
    }

    /// Host-specific AppleScript dispatch. Add new hosts here as
    /// their AppleScript dictionaries support window-by-tty queries.
    private static func ttyWindow(forHost host: HostConfig, tty: String) -> CGWindowID? {
        switch host.id {
        case "iterm2":
            return findITerm2Window(forTTY: tty)
        case "terminal-app":
            return findTerminalWindow(forTTY: tty)
        default:
            return nil
        }
    }

    /// iTerm2 exposes `tty` on each session inside each tab inside
    /// each window. `id of window` IS the CGWindowID per the
    /// "lessons learned" notes in CLAUDE.md.
    private static func findITerm2Window(forTTY tty: String) -> CGWindowID? {
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s is "\(tty)" then return id of w
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return 0
        """
        return runScriptForWindowID(script)
    }

    /// Terminal exposes `tty` on each tab. Same direct-CGWindowID
    /// trick.
    private static func findTerminalWindow(forTTY tty: String) -> CGWindowID? {
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t is "\(tty)" then return id of w
                    end try
                end repeat
            end repeat
        end tell
        return 0
        """
        return runScriptForWindowID(script)
    }

    private static func runScriptForWindowID(_ source: String) -> CGWindowID? {
        guard let descriptor = try? AppleScriptRunner.run(source) else { return nil }
        let raw = descriptor.int32Value
        guard raw != 0 else { return nil }
        return CGWindowID(UInt32(bitPattern: raw))
    }
}
