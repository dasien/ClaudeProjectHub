import AppKit
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

        // Resolve the target session (if any) to a CGWindowID. Required when
        // mode == .newTab; the launcher will surface a clear error if missing.
        let targetWindowID: CGWindowID? = targetSessionID.flatMap {
            windowManager.windowID(for: $0)
        }
        if windowMode == .newTab, targetSessionID != nil, targetWindowID == nil {
            presentError(LauncherError.targetWindowMissing)
            return false
        }

        // Snapshot the set of running `claude` PIDs *before* launch so the
        // post-launch diff identifies the new one we just started.
        let baselinePIDs = await currentClaudePIDs()

        do {
            let result = try await launcher.launch(
                in: cwd,
                mode: windowMode,
                targetWindowID: targetWindowID
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

        if let claudePID = await waitForNewClaudePID(baseline: baselinePIDs) {
            store.update(id: sessionID) { $0.pid = claudePID }
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
