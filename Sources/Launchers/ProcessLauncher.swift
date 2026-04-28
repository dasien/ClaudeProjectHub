import AppKit
import ApplicationServices
import CoreGraphics

/// Generic launcher for CLI-spawnable hosts (Ghostty, Alacritty, WezTerm,
/// kitty, etc.) defined entirely via JSON in hosts.json. The user adds an
/// entry with `strategy: { "type": "process", "executable": "...",
/// "arguments": [...] }` and this launcher invokes it.
///
/// Argument substitution tokens applied to each entry of `arguments`:
///   - `{cwd}`     → the cwd's absolute path (raw, unquoted)
///   - `{claude}`  → `claude` or `claude --resume <id>` (just the
///                   invocation, no cd)
///   - `{command}` → the full shell command:
///                   `cd '<cwd>' && claude [...]` (single-string for hosts
///                   with `-e <cmd>` style flags)
///
/// AX window discovery uses a pre/post window-set diff — these CLI hosts
/// don't return a window id from the spawn and their AX titles are
/// shell/program-driven, so the diff is the only reliable approach.
struct ProcessLauncher: SessionLauncher {
    let config: HostConfig

    init(config: HostConfig) {
        self.config = config
    }

    func isAvailable() -> Bool {
        guard case .process(let executable, _) = config.strategy else { return false }
        return FileManager.default.isExecutableFile(atPath: executable)
    }

    func launch(
        in cwd: URL,
        mode: WindowMode,
        targetWindowID: CGWindowID?,
        claudeArgs: [String]
    ) async throws -> LaunchResult {
        guard case .process(let executable, let arguments) = config.strategy else {
            throw LauncherError.unsupportedStrategy(
                "\(config.displayName) is not configured as a process-strategy host"
            )
        }
        guard isAvailable() else {
            throw LauncherError.hostNotInstalled(config.displayName)
        }

        // process-strategy hosts always create a new window per invocation —
        // there's no concept of "tab in existing window." The UI suppresses
        // the new-tab option for these (HostConfig.supportsNewTab == false),
        // but bail clearly if .newTab is somehow requested.
        if mode == .newTab {
            throw LauncherError.unsupportedStrategy(
                "\(config.displayName) doesn't support adding to existing windows"
            )
        }

        let marker = "ClaudeProjectHub-\(UUID().uuidString)"
        let substituted = arguments.map {
            substitute(token: $0, cwd: cwd, claudeArgs: claudeArgs)
        }

        // Snapshot existing host windows BEFORE spawn so we can identify
        // the new one. Empty set is fine — host might not be running yet.
        let preWindowIDs: Set<CGWindowID>
        if let pid = hostPID() {
            preWindowIDs = Set(AXSupport.windows(of: pid).compactMap {
                AXSupport.windowID(of: $0)
            })
        } else {
            preWindowIDs = []
        }

        // Detach standard streams so the child runs independently of us.
        // GUI apps don't want to inherit our fds.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = substituted
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw LauncherError.launchFailed(
                "Could not spawn \(executable): \(error.localizedDescription)"
            )
        }

        // Wait for the host app's process to register (it may have just
        // launched in response to our spawn).
        guard let pid = await waitForHostPID() else {
            throw LauncherError.windowNotFound(
                "\(config.displayName) didn't register as a running app within timeout. " +
                "Make sure the bundleIdentifier in hosts.json is correct."
            )
        }

        // Discover the new window via AX diff against the pre-launch snapshot.
        guard let newWindow = await AXSupport.waitForNewWindow(
            in: pid,
            excluding: preWindowIDs,
            timeout: 10
        ) else {
            throw LauncherError.windowNotFound(
                "Spawned \(config.displayName) but no new window appeared within 10s. " +
                "Check that the configured arguments actually open a window."
            )
        }

        return LaunchResult(marker: marker, preDiscoveredWindow: newWindow)
    }

    // MARK: - Helpers

    private func substitute(token: String, cwd: URL, claudeArgs: [String]) -> String {
        let cwdPath = cwd.path
        let claudeCmd = ShellCommand.claudeInvocation(args: claudeArgs)
        let fullCommand = ShellCommand.cdThenClaude(cwd: cwd, args: claudeArgs)
        return token
            .replacingOccurrences(of: "{cwd}", with: cwdPath)
            .replacingOccurrences(of: "{claude}", with: claudeCmd)
            .replacingOccurrences(of: "{command}", with: fullCommand)
    }

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
