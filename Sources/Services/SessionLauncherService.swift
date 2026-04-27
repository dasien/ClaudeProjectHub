import AppKit
import CoreGraphics
import Darwin
import SwiftUI

@MainActor
final class SessionLauncherService: ObservableObject {
    private let store: SessionStore
    private let windowManager: WindowManager
    private let launchers: [HostKind: SessionLauncher]
    private var hasRequestedAccessibility = false

    init(store: SessionStore, windowManager: WindowManager) {
        self.store = store
        self.windowManager = windowManager
        self.launchers = [
            .terminalApp: TerminalAppLauncher()
        ]
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
        hostKind: HostKind,
        windowMode: WindowMode,
        targetSessionID: Session.ID?
    ) async -> Bool {
        guard let launcher = launchers[hostKind] else {
            presentError(LauncherError.hostNotInstalled(hostKind.displayName))
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
            var session = result.session
            session.name = name?.isEmpty == false ? name : nil
            store.add(session)

            Task { [weak self] in
                await self?.discoverAndBind(
                    marker: result.marker,
                    sessionID: session.id,
                    hostKind: hostKind,
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
    func resume(_ session: Session) async -> Bool {
        guard session.status == .closed else { return false }
        guard let claudeSessionId = session.claudeSessionId else {
            presentError(LauncherError.missingClaudeSessionId)
            return false
        }
        guard let launcher = launchers[session.hostKind] else {
            presentError(LauncherError.hostNotInstalled(session.hostKind.displayName))
            return false
        }

        let baselinePIDs = await currentClaudePIDs()

        do {
            let result = try await launcher.launch(
                in: session.cwd,
                mode: .newWindow,
                targetWindowID: nil,
                claudeArgs: ["--resume", claudeSessionId]
            )
            // Reuse the existing Session record instead of adding a new one.
            store.update(id: session.id) {
                $0.status = .running
                $0.pid = nil
                $0.lastActivityAt = Date()
            }
            store.selectedSessionID = session.id

            Task { [weak self] in
                await self?.discoverAndBind(
                    marker: result.marker,
                    sessionID: session.id,
                    hostKind: session.hostKind,
                    baselinePIDs: baselinePIDs
                )
            }
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    // MARK: - Post-launch discovery

    private func discoverAndBind(
        marker: String,
        sessionID: Session.ID,
        hostKind: HostKind,
        baselinePIDs: Set<pid_t>
    ) async {
        guard let pid = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == hostKind.bundleIdentifier
        })?.processIdentifier else { return }

        guard let window = await AXSupport.findWindow(forMarker: marker, in: pid, timeout: 5) else {
            presentError(LauncherError.windowNotFound("timed out finding host window"))
            return
        }

        windowManager.bind(window, to: sessionID)

        // Capture the new claude PID, then read its sessions metadata file
        // to grab the Claude session UUID. The file at
        // `~/.claude/sessions/<pid>.json` is the authoritative per-process
        // record Claude maintains; it has sessionId, cwd, status, and a
        // live updatedAt — much more reliable than diffing the JSONL
        // directory and the canonical source for future external-session
        // adoption and idle/working detection.
        if let claudePID = await waitForNewClaudePID(baseline: baselinePIDs) {
            store.update(id: sessionID) { $0.pid = claudePID }
            if let sessionFile = await readClaudeSessionFile(pid: claudePID) {
                store.update(id: sessionID) { $0.claudeSessionId = sessionFile.sessionId }
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

    // MARK: - Claude sessions file

    /// Reads `~/.claude/sessions/<pid>.json`, polling briefly because the
    /// file might not exist the very first millisecond after the PID
    /// appears. Returns nil on timeout.
    private func readClaudeSessionFile(
        pid: pid_t,
        timeout: TimeInterval = 5
    ) async -> ClaudeSessionFile? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/\(pid).json")
        let deadline = Date().addingTimeInterval(timeout)
        let decoder = JSONDecoder()
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let file = try? decoder.decode(ClaudeSessionFile.self, from: data) {
                return file
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
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

/// Subset of the JSON Claude writes to `~/.claude/sessions/<pid>.json`.
/// Fields beyond `sessionId` are optional in case the schema shifts across
/// Claude versions.
private struct ClaudeSessionFile: Decodable {
    let sessionId: String
    let pid: Int32?
    let cwd: String?
    let status: String?
    let updatedAt: Int64?
    let kind: String?
    let entrypoint: String?
    let version: String?
}
