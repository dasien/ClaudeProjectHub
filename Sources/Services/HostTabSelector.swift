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
@MainActor
enum HostTabSelector {
    static func selectTab(hostID: String, tabIdentifier: String) {
        switch hostID {
        case "iterm2":
            selectITerm2Tab(tty: tabIdentifier)
        case "terminal-app":
            selectTerminalTab(tty: tabIdentifier)
        default:
            break
        }
    }

    private static func selectITerm2Tab(tty: String) {
        let script = """
        tell application "iTerm"
            repeat with w in windows
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
            end repeat
        end tell
        """
        _ = try? AppleScriptRunner.run(script)
    }

    private static func selectTerminalTab(tty: String) {
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
        _ = try? AppleScriptRunner.run(script)
    }
}
