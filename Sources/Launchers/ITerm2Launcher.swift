import AppKit
import ApplicationServices
import CoreGraphics

/// Launcher for iTerm2 (com.googlecode.iterm2).
///
/// iTerm2's AppleScript dictionary properly supports `create window` and
/// `create tab` (unlike Terminal.app, where those commands are listed but
/// non-functional). So we can drive both new-window and new-tab creation
/// straight from AppleScript — no System Events keystroke trickery, no
/// menu-press dance. AX raise is still used to bring the user's chosen
/// target window forward before adding a tab to it.
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

        let wasRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }

        switch (wasRunning, mode) {
        case (false, _), (true, .newWindow):
            try AppleScriptRunner.run(newWindowScript(runCommand: runCommand, marker: marker))

        case (true, .newTab):
            // Resolve the target AX window from the requested CGWindowID,
            // raise it to be iTerm2's current window, then ask AppleScript to
            // add a tab to "current window".
            guard let cgID = targetWindowID,
                  let pid = iterm2PID(),
                  let target = AXSupport.windows(of: pid).first(where: {
                      AXSupport.windowID(of: $0) == cgID
                  }) else {
                throw LauncherError.targetWindowMissing
            }
            NSRunningApplication(processIdentifier: pid)?.activate()
            AXSupport.raise(target)
            try await Task.sleep(nanoseconds: 200_000_000)
            try AppleScriptRunner.run(newTabScript(runCommand: runCommand, marker: marker))
        }

        return LaunchResult(marker: marker)
    }

    // MARK: - AppleScripts

    /// `create window with default profile` makes a new iTerm2 window. We
    /// then write our `cd && claude` into its current session and set the
    /// session's name to the marker so AX-based discovery can find it later.
    private func newWindowScript(runCommand: String, marker: String) -> String {
        """
        tell application "iTerm"
            activate
            create window with default profile
            tell current session of current window
                write text "\(runCommand)"
                set name to "\(marker)"
            end tell
        end tell
        """
    }

    /// Adds a tab to "current window" — caller (Swift) is responsible for
    /// having raised the right window via AX before this script runs.
    private func newTabScript(runCommand: String, marker: String) -> String {
        """
        tell application "iTerm"
            activate
            tell current window
                create tab with default profile
                tell current session of current tab
                    write text "\(runCommand)"
                    set name to "\(marker)"
                end tell
            end tell
        end tell
        """
    }

    private func iterm2PID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier
        }?.processIdentifier
    }
}
