import AppKit
import ApplicationServices
import CoreGraphics

struct TerminalAppLauncher: SessionLauncher {
    let hostKind: HostKind = .terminalApp

    func isAvailable() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: hostKind.bundleIdentifier) != nil
    }

    func launch(
        in cwd: URL,
        mode: WindowMode,
        targetWindowID: CGWindowID?
    ) async throws -> LaunchResult {
        guard isAvailable() else {
            throw LauncherError.hostNotInstalled(hostKind.displayName)
        }

        let marker = "ClaudeProjectHub-\(UUID().uuidString)"
        let cwdEscaped = cwd.path.replacingOccurrences(of: "'", with: "'\\''")

        let wasRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == hostKind.bundleIdentifier
        }

        if !wasRunning {
            // Cold start: AppleScript activates Terminal, which opens its
            // startup window per user prefs. Run the command in that window's
            // existing tab so we don't end up with two windows.
            try AppleScriptRunner.run(coldStartScript(cwdEscaped: cwdEscaped, marker: marker))
        } else {
            // Warm start: drive tab/window creation via AX (menu item press)
            // for determinism — System Events keystrokes depend on OS focus
            // propagation that's racy with `set index of window to 1`. AX
            // menu press operates on the app's internal state directly.
            try await warmStart(
                mode: mode,
                targetWindowID: targetWindowID,
                cwdEscaped: cwdEscaped,
                marker: marker
            )
        }

        let session = Session(
            cwd: cwd,
            hostKind: hostKind,
            status: .running
        )
        return LaunchResult(session: session, marker: marker)
    }

    // MARK: - Cold start (Terminal not running)

    private func coldStartScript(cwdEscaped: String, marker: String) -> String {
        """
        tell application "Terminal"
            activate
            set tries to 0
            repeat while (count of windows) = 0 and tries < 40
                delay 0.05
                set tries to tries + 1
            end repeat
            if (count of windows) > 0 then
                set newTab to do script "cd '\(cwdEscaped)' && claude" in (selected tab of window 1)
            else
                set newTab to do script "cd '\(cwdEscaped)' && claude"
            end if
            set custom title of newTab to "\(marker)"
        end tell
        """
    }

    // MARK: - Warm start (Terminal already running)

    private func warmStart(
        mode: WindowMode,
        targetWindowID: CGWindowID?,
        cwdEscaped: String,
        marker: String
    ) async throws {
        guard let terminalPID = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == hostKind.bundleIdentifier
        })?.processIdentifier else {
            throw LauncherError.launchFailed("Terminal is no longer running.")
        }

        NSRunningApplication(processIdentifier: terminalPID)?.activate()

        // For newTab, raise the chosen window via AX *first*. AXRaise updates
        // OS-level focus (which is what System Events keystrokes target),
        // unlike AppleScript's `set index to 1` which only updates Terminal's
        // own window ordering and lets the keystroke fall into whichever
        // window the OS still considered front.
        if mode == .newTab {
            guard let cgID = targetWindowID,
                  let targetWindow = resolveAXWindow(matching: cgID, in: terminalPID) else {
                throw LauncherError.targetWindowMissing
            }
            let title = AXSupport.title(of: targetWindow) ?? "<no title>"
            print("[TerminalAppLauncher] raising AX window cgID=\(cgID) title=\(title)")
            AXSupport.raise(targetWindow)
        }

        // Give activation + raise time to propagate to WindowServer before
        // the keystroke fires. AX raise is synchronous from the app's
        // perspective but OS focus update can lag a frame or two.
        try await Task.sleep(nanoseconds: 200_000_000)
        print("[TerminalAppLauncher] running AppleScript for mode=\(mode)")

        let keystroke = (mode == .newTab) ? "t" : "n"
        let unit = (mode == .newTab) ? "tab" : "window"

        // Snapshot every Terminal window's tab count, fire the keystroke, then
        // poll for ANY window whose tab count went up (or a brand-new window
        // appearing). Identifying the new tab by where it actually landed
        // — instead of by `count of tabs of front window` — sidesteps the
        // ambiguity of which window AppleScript considers "front" at any
        // particular moment, and protects against the case where focus
        // didn't fully propagate to our raised window.
        let script = """
        tell application "Terminal" to activate
        tell application "System Events"
            set frontTries to 0
            repeat while (frontmost of process "Terminal") is false and frontTries < 40
                delay 0.05
                set frontTries to frontTries + 1
            end repeat
        end tell
        set initialMap to {}
        tell application "Terminal"
            repeat with w in windows
                copy {id of w, count of tabs of w} to end of initialMap
            end repeat
        end tell
        tell application "System Events"
            keystroke "\(keystroke)" using {command down}
        end tell
        set foundWindowID to 0
        set tries to 0
        repeat while foundWindowID is 0 and tries < 40
            delay 0.05
            set tries to tries + 1
            tell application "Terminal"
                repeat with w in windows
                    set wID to id of w
                    set currentTabs to count of tabs of w
                    set wasKnown to false
                    set initialTabs to 0
                    repeat with j from 1 to count of initialMap
                        set entry to item j of initialMap
                        if (item 1 of entry) is wID then
                            set wasKnown to true
                            set initialTabs to (item 2 of entry)
                            exit repeat
                        end if
                    end repeat
                    if wasKnown is false and currentTabs > 0 then
                        set foundWindowID to wID
                        exit repeat
                    else if wasKnown and currentTabs > initialTabs then
                        set foundWindowID to wID
                        exit repeat
                    end if
                end repeat
            end tell
        end repeat
        if foundWindowID is 0 then
            set diag to "initial=["
            repeat with j from 1 to count of initialMap
                set entry to item j of initialMap
                set diag to diag & "w" & (item 1 of entry) & "=" & (item 2 of entry)
                if j < (count of initialMap) then set diag to diag & ","
            end repeat
            set diag to diag & "] current=["
            tell application "Terminal"
                set wlist to windows
                set wcount to count of wlist
                repeat with k from 1 to wcount
                    set w to item k of wlist
                    set diag to diag & "w" & (id of w) & "=" & (count of tabs of w)
                    if k < wcount then set diag to diag & ","
                end repeat
            end tell
            set diag to diag & "]"
            error "Could not detect a new \(unit) after Cmd-\(keystroke.uppercased()). " & diag
        end if
        tell application "Terminal"
            set foundWindow to (first window whose id is foundWindowID)
            set newTab to do script "cd '\(cwdEscaped)' && claude" in (selected tab of foundWindow)
            set custom title of newTab to "\(marker)"
        end tell
        """
        try AppleScriptRunner.run(script)
    }

    private func resolveAXWindow(matching cgID: CGWindowID, in pid: pid_t) -> AXUIElement? {
        AXSupport.windows(of: pid).first { AXSupport.windowID(of: $0) == cgID }
    }
}
