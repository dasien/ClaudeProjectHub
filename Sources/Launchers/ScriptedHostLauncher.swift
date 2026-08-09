import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The single launcher for every host. Reads the host's `.applescript`
/// from the user's scripts directory, substitutes hub-supplied
/// placeholders, runs it, and binds the resulting window via AX.
///
/// The script does the launching — `do shell script`, `tell application`,
/// System Events keystrokes, whatever fits the host. Swift only handles:
///
///   1. AX-raising the user-picked target window for newTab mode (so
///      System Events keystrokes inside the script land on the right
///      window without each script having to reinvent that dance).
///   2. Reading the script's return value as a CGWindowID. Positive
///      integer → look up the AX element directly. Zero → fall back to
///      AX-diff against a pre-launch window snapshot.
///
/// Scripts that AppleScript-natively know their window's id (Terminal,
/// iTerm2) take the fast path. Scripts that just `do shell script` a CLI
/// terminal can `return 0` and let Swift handle discovery.
struct ScriptedHostLauncher: SessionLauncher {
    let config: HostConfig
    let scriptURL: URL

    init(config: HostConfig, scriptURL: URL) {
        self.config = config
        self.scriptURL = scriptURL
    }

    func isAvailable() -> Bool {
        FileManager.default.isReadableFile(atPath: scriptURL.path)
    }

    func launch(
        in cwd: URL,
        mode: WindowMode,
        targetWindowID: CGWindowID?,
        claudeArgs: [String],
        claudeEnv: [String: String] = [:]
    ) async throws -> LaunchResult {
        guard isAvailable() else {
            throw LauncherError.launchFailed(
                "Launch script not found at \(scriptURL.path). " +
                "Add or restore \(config.launchScript) in " +
                "~/Library/Application Support/ClaudeProjectHub/scripts/."
            )
        }

        let template: String
        do {
            template = try String(contentsOf: scriptURL, encoding: .utf8)
        } catch {
            throw LauncherError.launchFailed(
                "Could not read script \(config.launchScript): \(error.localizedDescription)"
            )
        }

        let marker = "ClaudeProjectHub-\(UUID().uuidString)"
        let claudeCmd = ShellCommand.claudeInvocation(args: claudeArgs, env: claudeEnv)

        // For newTab mode the script's `keystroke`/`tell current window`
        // logic targets whatever window the OS considers front. AX-raise
        // the user's pick from Swift first so the script doesn't have to.
        let preDiscoveredFromTarget: AXUIElement?
        if mode == .newTab {
            guard let cgID = targetWindowID,
                  let pid = hostPID(),
                  let target = AXSupport.windows(of: pid).first(where: {
                      AXSupport.windowID(of: $0) == cgID
                  }) else {
                throw LauncherError.targetWindowMissing
            }
            NSRunningApplication(processIdentifier: pid)?.activate()
            AXSupport.raise(target)
            try await Task.sleep(nanoseconds: 200_000_000)
            preDiscoveredFromTarget = target
        } else {
            preDiscoveredFromTarget = nil
        }

        // Snapshot the host's existing windows BEFORE running the script,
        // in case the script returns 0 and we need an AX diff to find the
        // new one.
        let preWindowIDs: Set<CGWindowID> = {
            guard let pid = hostPID() else { return [] }
            return Set(AXSupport.windows(of: pid).compactMap {
                AXSupport.windowID(of: $0)
            })
        }()

        let source = substitute(
            template: template,
            cwd: cwd,
            claudeCmd: claudeCmd,
            marker: marker,
            mode: mode,
            targetWindowID: targetWindowID
        )

        let descriptor: NSAppleEventDescriptor
        do {
            descriptor = try AppleScriptRunner.run(source)
        } catch {
            throw LauncherError.launchFailed(error.localizedDescription)
        }

        // Wait for the host process to register if the script just spawned
        // it cold. Without this, `pid` lookups can race the launch.
        guard let pid = await waitForHostPID() else {
            throw LauncherError.windowNotFound(
                "\(config.displayName) didn't register as a running app within timeout. " +
                "Make sure the bundle identifier in Settings is correct."
            )
        }

        let returnedWindowID = readWindowID(from: descriptor)
        let preDiscoveredWindow: AXUIElement?

        if let cgID = returnedWindowID {
            // Script told us exactly which window. Bind it directly.
            preDiscoveredWindow = await AXSupport.waitForWindow(matching: cgID, in: pid)
                ?? preDiscoveredFromTarget
        } else {
            // Script returned 0 (or a non-integer). Fall back to AX diff —
            // the new window is the one that wasn't in our pre-launch
            // snapshot.
            if let found = await AXSupport.waitForNewWindow(
                in: pid,
                excluding: preWindowIDs,
                timeout: 10
            ) {
                preDiscoveredWindow = found
            } else {
                preDiscoveredWindow = preDiscoveredFromTarget
            }
        }

        return LaunchResult(marker: marker, preDiscoveredWindow: preDiscoveredWindow)
    }

    // MARK: - Substitution

    /// Replaces `{cwd}`, `{claude}`, `{marker}`, `{mode}`,
    /// `{targetWindowID}`, and `{bundleID}` in the template.
    /// Substituted strings are AppleScript-escaped (backslash,
    /// double-quote) so users can drop them straight into string
    /// literals like `"{cwd}"`.
    private func substitute(
        template: String,
        cwd: URL,
        claudeCmd: String,
        marker: String,
        mode: WindowMode,
        targetWindowID: CGWindowID?
    ) -> String {
        let modeString: String
        switch mode {
        case .newWindow: modeString = "newWindow"
        case .newTab:    modeString = "newTab"
        }
        let targetIDString = targetWindowID.map { String($0) } ?? "0"
        let bundleID = config.bundleIdentifier ?? ""

        return template
            .replacingOccurrences(of: "{cwd}",            with: appleScriptEscape(cwd.path))
            .replacingOccurrences(of: "{claude}",         with: appleScriptEscape(claudeCmd))
            .replacingOccurrences(of: "{marker}",         with: appleScriptEscape(marker))
            .replacingOccurrences(of: "{mode}",           with: modeString)
            .replacingOccurrences(of: "{targetWindowID}", with: targetIDString)
            .replacingOccurrences(of: "{bundleID}",       with: appleScriptEscape(bundleID))
    }

    private func appleScriptEscape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Return value

    /// Reads the AppleScript return as a CGWindowID. Returns nil if the
    /// script returned 0 or a non-integer (which is the signal to fall
    /// back to AX-diff discovery).
    private func readWindowID(from descriptor: NSAppleEventDescriptor) -> CGWindowID? {
        // NSAppleScript returns a typeAEList wrapping the value, so just
        // pull the int32 out and reinterpret as unsigned.
        let raw = descriptor.int32Value
        guard raw != 0 else { return nil }
        return CGWindowID(UInt32(bitPattern: raw))
    }

    // MARK: - Host PID

    private func hostPID() -> pid_t? {
        guard let bundleID = config.bundleIdentifier else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }?.processIdentifier
    }

    private func waitForHostPID(timeout: TimeInterval = 5) async -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = hostPID() {
                return pid
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }
}
