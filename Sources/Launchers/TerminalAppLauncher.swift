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
        targetWindowID: CGWindowID?,
        claudeArgs: [String]
    ) async throws -> LaunchResult {
        guard isAvailable() else {
            throw LauncherError.hostNotInstalled(hostKind.displayName)
        }

        let marker = "ClaudeProjectHub-\(UUID().uuidString)"
        let cwdEscaped = shellQuote(cwd.path)
        let claudeCommand = buildClaudeCommand(args: claudeArgs)
        let runCommand = "cd \(cwdEscaped) && \(claudeCommand)"

        let wasRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == hostKind.bundleIdentifier
        }

        if !wasRunning {
            try AppleScriptRunner.run(coldStartScript(runCommand: runCommand, marker: marker))
        } else {
            try await warmStart(
                mode: mode,
                targetWindowID: targetWindowID,
                runCommand: runCommand,
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

    private func coldStartScript(runCommand: String, marker: String) -> String {
        """
        tell application "Terminal"
            activate
            set tries to 0
            repeat while (count of windows) = 0 and tries < 40
                delay 0.05
                set tries to tries + 1
            end repeat
            if (count of windows) > 0 then
                set newTab to do script "\(runCommand)" in (selected tab of window 1)
            else
                set newTab to do script "\(runCommand)"
            end if
            set custom title of newTab to "\(marker)"
        end tell
        """
    }

    // MARK: - Warm start (Terminal already running)

    private func warmStart(
        mode: WindowMode,
        targetWindowID: CGWindowID?,
        runCommand: String,
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
            AXSupport.raise(targetWindow)
        }

        // Give activation + raise time to propagate to WindowServer before
        // the keystroke fires. AX raise is synchronous from the app's
        // perspective but OS focus update can lag a frame or two.
        try await Task.sleep(nanoseconds: 200_000_000)

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
            error "Could not detect a new \(unit) after Cmd-\(keystroke.uppercased()). Check Terminal's keyboard shortcuts."
        end if
        tell application "Terminal"
            set foundWindow to (first window whose id is foundWindowID)
            set newTab to do script "\(runCommand)" in (selected tab of foundWindow)
            set custom title of newTab to "\(marker)"
        end tell
        """
        try AppleScriptRunner.run(script)
    }

    private func resolveAXWindow(matching cgID: CGWindowID, in pid: pid_t) -> AXUIElement? {
        AXSupport.windows(of: pid).first { AXSupport.windowID(of: $0) == cgID }
    }

    // MARK: - Shell command building

    private func buildClaudeCommand(args: [String]) -> String {
        guard !args.isEmpty else { return "claude" }
        let escaped = args.map { shellQuote($0) }.joined(separator: " ")
        return "claude \(escaped)"
    }

    /// Shell-quote a string so it survives intact through `do script` →
    /// AppleScript string literal → bash. Wraps in single quotes and escapes
    /// any literal single quotes within.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
