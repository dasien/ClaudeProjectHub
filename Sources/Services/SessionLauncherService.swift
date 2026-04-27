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

        // Snapshot before launch so post-launch diffs identify what's new.
        let baselinePIDs = await currentClaudePIDs()
        let baselineJSONLs = currentClaudeJSONLs(for: cwd)

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
                    cwd: cwd,
                    baselinePIDs: baselinePIDs,
                    baselineJSONLs: baselineJSONLs
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
                    cwd: session.cwd,
                    baselinePIDs: baselinePIDs,
                    baselineJSONLs: nil  // claudeSessionId already known
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
        cwd: URL,
        baselinePIDs: Set<pid_t>,
        baselineJSONLs: Set<URL>?
    ) async {
        guard let pid = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == hostKind.bundleIdentifier
        })?.processIdentifier else { return }

        guard let window = await AXSupport.findWindow(forMarker: marker, in: pid, timeout: 5) else {
            presentError(LauncherError.windowNotFound("timed out finding host window"))
            return
        }

        windowManager.bind(window, to: sessionID)

        if let claudePID = await waitForNewClaudePID(baseline: baselinePIDs) {
            store.update(id: sessionID) { $0.pid = claudePID }
        }

        // Skipped on resume — the session already has a claudeSessionId and
        // `claude --resume` appends to the existing JSONL rather than
        // creating a new one, so the diff would never find a "new" file.
        if let baseline = baselineJSONLs,
           let claudeSessionId = await captureClaudeSessionID(for: cwd, baseline: baseline) {
            store.update(id: sessionID) { $0.claudeSessionId = claudeSessionId }
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

    // MARK: - claudeSessionId discovery

    /// Snapshot of the JSONL files currently in `~/.claude/projects/<encoded>/`
    /// for this cwd. Used as a baseline so we can identify the new file the
    /// freshly-launched `claude` will create.
    private func currentClaudeJSONLs(for cwd: URL) -> Set<URL> {
        let dir = claudeProjectsDirectory(for: cwd)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return Set(contents.filter { $0.pathExtension == "jsonl" })
    }

    private func captureClaudeSessionID(
        for cwd: URL,
        baseline: Set<URL>,
        timeout: TimeInterval = 15
    ) async -> String? {
        let dir = claudeProjectsDirectory(for: cwd)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) {
                let jsonls = Set(contents.filter { $0.pathExtension == "jsonl" })
                if let new = jsonls.subtracting(baseline).first {
                    return new.deletingPathExtension().lastPathComponent
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    private func claudeProjectsDirectory(for cwd: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".claude/projects/\(cwd.claudeProjectsDirectoryName)")
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
