import AppKit
import CoreGraphics
import Darwin
import SwiftUI

@MainActor
final class SessionLauncherService: ObservableObject {
    private let store: SessionStore
    private let windowManager: WindowManager
    private let hostRegistry: HostRegistry
    private var hasRequestedAccessibility = false

    init(store: SessionStore, windowManager: WindowManager, hostRegistry: HostRegistry) {
        self.store = store
        self.windowManager = windowManager
        self.hostRegistry = hostRegistry
    }

    /// Checks Accessibility access and either returns true (proceed) or
    /// triggers the OS prompt / "relaunch required" alert and returns false.
    /// Callers should bail when this returns false.
    func ensureAccessibilityOrPrompt() -> Bool {
        if AccessibilityService.isTrusted { return true }

        if hasRequestedAccessibility {
            showRelaunchRequiredAlert()
        } else {
            hasRequestedAccessibility = true
            AccessibilityService.requestTrust(promptIfNeeded: true)
        }
        return false
    }

    @discardableResult
    func launch(
        name: String?,
        cwd: URL,
        hostID: String,
        windowMode: WindowMode,
        targetSessionID: Session.ID?
    ) async -> Bool {
        guard let config = hostRegistry.host(forID: hostID) else {
            presentError(LauncherError.unknownHost(hostID))
            return false
        }
        let launcher: SessionLauncher
        do {
            launcher = try makeLauncher(for: config)
        } catch {
            presentError(error)
            return false
        }

        let targetWindowID: CGWindowID? = targetSessionID.flatMap {
            windowManager.windowID(for: $0)
        }
        if windowMode == .newTab, targetSessionID != nil, targetWindowID == nil {
            presentError(LauncherError.targetWindowMissing)
            return false
        }

        // Snapshot existing claude PIDs before launch so we can identify the
        // new one we just started.
        let baselinePIDs = await currentClaudePIDs()

        do {
            let result = try await launcher.launch(
                in: cwd,
                mode: windowMode,
                targetWindowID: targetWindowID,
                claudeArgs: []
            )
            let session = Session(
                name: name?.isEmpty == false ? name : nil,
                cwd: cwd,
                hostID: hostID,
                status: .idle
            )
            store.add(session)

            Task { [weak self] in
                await self?.discoverAndBind(
                    marker: result.marker,
                    preDiscoveredWindow: result.preDiscoveredWindow,
                    sessionID: session.id,
                    bundleIdentifier: config.bundleIdentifier,
                    baselinePIDs: baselinePIDs
                )
            }
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    /// Reactivates a closed session by relaunching `claude --resume <id>` in
    /// the original cwd via the original host. The same Session record is
    /// reused — its status flips back to running and it gets a new host
    /// window. The claudeSessionId is unchanged because `--resume` continues
    /// the same conversation.
    @discardableResult
    func resume(
        _ session: Session,
        windowMode: WindowMode = .newWindow,
        targetSessionID: Session.ID? = nil
    ) async -> Bool {
        guard session.status == .closed else { return false }
        guard let claudeSessionId = session.claudeSessionId else {
            presentError(LauncherError.missingClaudeSessionId)
            return false
        }
        guard let config = hostRegistry.host(forID: session.hostID) else {
            presentError(LauncherError.unknownHost(session.hostID))
            return false
        }
        let launcher: SessionLauncher
        do {
            launcher = try makeLauncher(for: config)
        } catch {
            presentError(error)
            return false
        }

        // Claude assigns a sessionId at process startup but only writes the
        // conversation JSONL once a message is exchanged. If the user opened
        // a session and closed it without typing anything, `--resume` errors
        // with "No conversation found". Catch that case here with a clearer
        // message instead of dumping the error into a fresh Terminal window.
        // Also self-heal: pre-fix builds overwrote claudeSessionId on every
        // resume with the resumed process's new id (which has no JSONL),
        // leaving records that can't be resumed. If we can unambiguously
        // identify the right JSONL in the cwd's directory, recover it.
        var resumedSessionId = claudeSessionId
        let initialJsonl = jsonlPath(for: session.cwd, sessionId: resumedSessionId)
        if !FileManager.default.fileExists(atPath: initialJsonl.path) {
            if let recovered = recoverSessionId(for: session.cwd) {
                resumedSessionId = recovered
                store.update(id: session.id) { $0.claudeSessionId = recovered }
            } else {
                presentError(LauncherError.launchFailed(
                    "This session has no recorded conversation to resume. " +
                    "Claude only writes the transcript once the first message " +
                    "is exchanged, and this session was closed before that " +
                    "happened. Start a new session in this directory instead."
                ))
                return false
            }
        }

        let targetWindowID: CGWindowID? = targetSessionID.flatMap {
            windowManager.windowID(for: $0)
        }
        if windowMode == .newTab, targetSessionID != nil, targetWindowID == nil {
            presentError(LauncherError.targetWindowMissing)
            return false
        }

        let baselinePIDs = await currentClaudePIDs()

        do {
            let result = try await launcher.launch(
                in: session.cwd,
                mode: windowMode,
                targetWindowID: targetWindowID,
                claudeArgs: ["--resume", resumedSessionId]
            )
            // Reuse the existing Session record instead of adding a new one.
            store.update(id: session.id) {
                $0.status = .idle
                $0.pid = nil
                $0.lastActivityAt = Date()
            }
            store.selectedSessionID = session.id

            Task { [weak self] in
                await self?.discoverAndBind(
                    marker: result.marker,
                    preDiscoveredWindow: result.preDiscoveredWindow,
                    sessionID: session.id,
                    bundleIdentifier: config.bundleIdentifier,
                    baselinePIDs: baselinePIDs
                )
            }
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    // MARK: - Strategy dispatch

    private func makeLauncher(for config: HostConfig) throws -> SessionLauncher {
        switch config.strategy {
        case .builtin(let kind):
            switch kind {
            case .terminalApp:
                return TerminalAppLauncher()
            case .iterm2:
                return ITerm2Launcher()
            }
        case .process:
            return ProcessLauncher(config: config)
        }
    }

    // MARK: - Post-launch discovery

    private func discoverAndBind(
        marker: String,
        preDiscoveredWindow: AXUIElement?,
        sessionID: Session.ID,
        bundleIdentifier: String?,
        baselinePIDs: Set<pid_t>
    ) async {
        guard let bundleIdentifier,
              let pid = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == bundleIdentifier
              })?.processIdentifier else { return }

        // Prefer the launcher's pre-discovered window when it set one (e.g.
        // iTerm2 uses a window-set diff to find the new window directly).
        // Fall back to marker-based title search otherwise (used by Terminal,
        // whose AX window title reflects our custom tab title).
        let window: AXUIElement
        if let pre = preDiscoveredWindow {
            window = pre
        } else if let found = await AXSupport.findWindow(forMarker: marker, in: pid, timeout: 5) {
            window = found
        } else {
            presentError(LauncherError.windowNotFound("timed out finding host window"))
            return
        }

        windowManager.bind(window, to: sessionID)

        if let claudePID = await waitForNewClaudePID(baseline: baselinePIDs) {
            store.update(id: sessionID) { $0.pid = claudePID }
            if let sessionFile = await ClaudeSessionFile.read(pid: claudePID, timeout: 5) {
                // Set-once: `claude --resume <id>` assigns a NEW sessionId to
                // the resumed process (visible in ~/.claude/sessions/<pid>.json),
                // but the conversation continues to be written to the ORIGINAL
                // session's JSONL. Overwriting here would point the record at
                // a process-only id that has no JSONL of its own, breaking the
                // next Resume.
                store.update(id: sessionID) {
                    if $0.claudeSessionId == nil {
                        $0.claudeSessionId = sessionFile.sessionId
                    }
                }
            }
        }
    }

    // MARK: - claude PID discovery

    private func waitForNewClaudePID(
        baseline: Set<pid_t>,
        timeout: TimeInterval = 8
    ) async -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = await currentClaudePIDs()
            if let new = now.subtracting(baseline).first {
                return new
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    private func currentClaudePIDs() async -> Set<pid_t> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return []
        }
        task.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        return Set(output.split(separator: "\n").compactMap { pid_t($0) })
    }

    // MARK: - JSONL transcript path

    private func jsonlPath(for cwd: URL, sessionId: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(cwd.claudeProjectsDirectoryName)/\(sessionId).jsonl")
    }

    /// Used to repair sessions whose `claudeSessionId` was clobbered by an
    /// earlier bug where every resume overwrote it with the resumed
    /// process's id. Returns a recovered sessionId only when there's
    /// exactly one JSONL in the cwd's encoded directory, so we never
    /// silently pick the wrong one.
    private func recoverSessionId(for cwd: URL) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(cwd.claudeProjectsDirectoryName)")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return nil }
        let jsonls = contents.filter { $0.pathExtension == "jsonl" }
        return jsonls.count == 1 ? jsonls.first?.deletingPathExtension().lastPathComponent : nil
    }

    // MARK: - Permission + error UI

    private func showRelaunchRequiredAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Relaunch required"
        alert.informativeText = """
        If you've granted Accessibility access in System Settings, the change may not apply until Claude Project Hub is relaunched. Quit (⌘Q) and reopen the app.

        If you don't see Claude Project Hub in System Settings → Privacy & Security → Accessibility, or you see multiple entries, remove old entries and try again.
        """
        alert.addButton(withTitle: "Quit Now")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not launch session"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private extension URL {
    /// Filename Claude uses for this directory under `~/.claude/projects/`.
    /// Per Claude's convention: every non-alphanumeric (ASCII) character is
    /// replaced with `-`. So `/Users/me/Source/foo` becomes
    /// `-Users-me-Source-foo`.
    var claudeProjectsDirectoryName: String {
        var result = ""
        for char in standardizedFileURL.path {
            if char.isASCII && (char.isLetter || char.isNumber) {
                result.append(char)
            } else {
                result.append("-")
            }
        }
        return result
    }
}
