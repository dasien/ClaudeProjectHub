import Foundation

/// One entry in the host registry. Defines an application that can host
/// Claude Code sessions. Loaded from
/// `~/Library/Application Support/ClaudeProjectHub/hosts.json`.
///
/// The launch behavior for each host lives entirely in a separate
/// AppleScript file referenced by `launchScript`. There's no in-app
/// distinction between "built-in" and "process" hosts — every host is
/// driven by the same `ScriptedHostLauncher` against its script.
struct HostConfig: Codable, Identifiable, Hashable {
    /// Stable identifier — referenced by `Session.hostID`. Slug-cased,
    /// derived from `displayName` at creation. Locked once a host exists
    /// because existing sessions reference it.
    var id: String
    var displayName: String
    /// Used to find the host's running process via NSWorkspace and to
    /// resolve the host's app icon for display. Required in practice;
    /// optional only for edge cases where the host isn't a registered
    /// .app bundle.
    var bundleIdentifier: String?
    /// Filename (e.g. "terminal-app.applescript") within
    /// `~/Library/Application Support/ClaudeProjectHub/scripts/`. The
    /// script itself does the launching — `do shell script` for CLI
    /// hosts, `tell application` for AppleScript-aware hosts, System
    /// Events keystrokes for IDE plugins, all in one file per host.
    var launchScript: String
}

extension HostConfig {
    /// Which family of AppleScript terminology this host's **application**
    /// speaks for the two things the hub needs beyond launching: looking up
    /// a window by a session's controlling tty, and selecting or closing one
    /// tab within a window. nil means the app gives us neither.
    ///
    /// **Keyed on `bundleIdentifier`, deliberately not on `id`.** The
    /// capability belongs to the application, not to the hub's local name
    /// for it. This used to be a `switch` on `id` matching the two shipped
    /// ids literally, which silently degraded every *user-added* host —
    /// Settings → Hosts slugs the id from the display name, so a second
    /// Terminal- or iTerm2-backed host (say `id: "terminal-no-login"`)
    /// matched nothing and lost tty→window resolution and per-tab
    /// switching even though the underlying app supports both.
    ///
    /// Contrast `supportsNewTab` below, which keys on the *script* filename
    /// and is right to: newTab mode is implemented by the launch script, so
    /// that capability really is per-script. Two capabilities, two different
    /// keys, for two different reasons.
    enum TerminalScripting {
        case terminal
        case iTerm2
    }

    var terminalScripting: TerminalScripting? {
        // Lowercased because LaunchServices lookup is case-insensitive, so
        // a hand-edited hosts.json may not match our casing.
        switch bundleIdentifier?.lowercased() {
        case "com.apple.terminal":
            return .terminal
        case "com.googlecode.iterm2":
            return .iTerm2
        default:
            return nil
        }
    }

    /// Whether this host supports adding a new tab to an existing window.
    /// Currently inferred from the script file's name — a hosts.json
    /// schema field could make this explicit later, but for now we treat
    /// only Terminal and iTerm2 as tab-capable since their default
    /// scripts handle the `newTab` mode. Other hosts default to
    /// new-window-only.
    var supportsNewTab: Bool {
        // Heuristic: if the user is using one of the bundled tab-capable
        // scripts, expose newTab in the UI. Otherwise hide it.
        switch launchScript {
        case "terminal-app.applescript", "iterm2.applescript":
            return true
        default:
            return false
        }
    }
}
