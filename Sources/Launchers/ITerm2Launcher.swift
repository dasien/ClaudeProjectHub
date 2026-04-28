import AppKit
import ApplicationServices
import CoreGraphics

/// Launcher for iTerm2 (com.googlecode.iterm2).
///
/// iTerm2's AppleScript dictionary properly supports `create window` and
/// `create tab` directly (unlike Terminal, where those commands are
/// listed but non-functional). So we drive both new-window and new-tab
/// creation straight from AppleScript — no System Events keystroke
/// trickery, no menu-press dance.
///
/// AX window binding: iTerm2's `id of window` IS the CGWindowID
/// (verified empirically — `CGWindowListCopyWindowInfo` returns iTerm2's
/// metadata when queried with that id). So the AppleScript returns the
/// new window's id and Swift looks up the matching AX element directly,
/// no marker matching or window-set diff needed.
struct ITerm2Launcher: SessionLauncher {
    private let bundleIdentifier = "com.googlecode.iterm2"
    private let displayName = "iTerm2"

    func isAvailable() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    func launch(
        in cwd: URL,
        mode: WindowMode,
        targetWindowID: CGWindowID?,
        claudeArgs: [String]
    ) async throws -> LaunchResult {
        guard isAvailable() else {
            throw LauncherError.hostNotInstalled(displayName)
        }

        let marker = "ClaudeProjectHub-\(UUID().uuidString)"
        let runCommand = ShellCommand.cdThenClaude(cwd: cwd, args: claudeArgs)

        let preDiscoveredWindow: AXUIElement?

        switch mode {
        case .newWindow:
            let descriptor = try AppleScriptRunner.run(
                newWindowScript(runCommand: runCommand, marker: marker)
            )
            let cgID = CGWindowID(UInt32(bitPattern: descriptor.int32Value))
            preDiscoveredWindow = await resolveAXWindow(cgID: cgID)

        case .newTab:
            // Resolve the user-chosen target window and raise it via AX so
            // iTerm2's "current window" matches before `create tab` runs.
            guard let targetCGID = targetWindowID,
                  let pid = iterm2PID(),
                  let target = AXSupport.windows(of: pid).first(where: {
                      AXSupport.windowID(of: $0) == targetCGID
                  }) else {
                throw LauncherError.targetWindowMissing
            }
            NSRunningApplication(processIdentifier: pid)?.activate()
            AXSupport.raise(target)
            try await Task.sleep(nanoseconds: 200_000_000)
            let descriptor = try AppleScriptRunner.run(
                newTabScript(runCommand: runCommand, marker: marker)
            )
            // Trust iTerm2's report of which window the tab landed in. If
            // focus didn't propagate and the tab landed elsewhere, this
            // still binds correctly to wherever claude is actually running.
            let cgID = CGWindowID(UInt32(bitPattern: descriptor.int32Value))
            preDiscoveredWindow = await resolveAXWindow(cgID: cgID) ?? target
        }

        return LaunchResult(marker: marker, preDiscoveredWindow: preDiscoveredWindow)
    }

    // MARK: - AppleScripts

    /// `create window with default profile` makes a new iTerm2 window. We
    /// write our `cd && claude` into its current session, set the session's
    /// name (cosmetic — visible in iTerm2's tab bar but not relied on for
    /// AX binding), and return the new window's id back to Swift.
    private func newWindowScript(runCommand: String, marker: String) -> String {
        """
        tell application "iTerm"
            activate
            create window with default profile
            set winID to id of current window
            tell current session of current window
                write text "\(runCommand)"
                set name to "\(marker)"
            end tell
            return winID
        end tell
        """
    }

    /// Adds a tab to "current window" — caller is responsible for having
    /// raised the right window via AX before this script runs.
    private func newTabScript(runCommand: String, marker: String) -> String {
        """
        tell application "iTerm"
            activate
            tell current window
                create tab with default profile
                set winID to id of current window
                tell current session of current tab
                    write text "\(runCommand)"
                    set name to "\(marker)"
                end tell
            end tell
            return winID
        end tell
        """
    }

    // MARK: - Helpers

    private func resolveAXWindow(cgID: CGWindowID) async -> AXUIElement? {
        guard let pid = iterm2PID() else { return nil }
        return await AXSupport.waitForWindow(matching: cgID, in: pid)
    }

    private func iterm2PID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier
        }?.processIdentifier
    }
}
