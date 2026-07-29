import AppKit
import CoreGraphics
import Darwin
import os.log
import SwiftUI

private let launcherLog = Logger(subsystem: "com.bgentry.ClaudeProjectHub", category: "Launcher")

@MainActor
final class SessionLauncherService: ObservableObject {
    private let store: SessionStore
    private let windowManager: WindowManager
    private let hostRegistry: HostRegistry
    private let dockController: DockController
    private var hasRequestedAccessibility = false
    private var didWakeObserver: NSObjectProtocol?

    init(
        store: SessionStore,
        windowManager: WindowManager,
        hostRegistry: HostRegistry,
        dockController: DockController
    ) {
        self.store = store
        self.windowManager = windowManager
        self.hostRegistry = hostRegistry
        self.dockController = dockController
        installWakeReattach()
    }

    deinit {
        if let token = didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    /// Subscribes to NSWorkspace.didWake. macOS fires spurious AX
    /// destroy notifications during sleep/wake — DockController's
    /// destroy handler already defers and re-checks each one against
    /// WindowServer, but that's per-window and reactive. This is the
    /// proactive complement: after every wake, walk every running
    /// session and run the same reattach path the hub uses at launch.
    /// Idempotent for sessions whose bindings are still good
    /// (`dockController.dock` no-ops when the session is already
    /// docked); re-binds + re-docks anything that fell out during
    /// sleep. The 1s settle delay lets WindowServer finish
    /// re-registering windows before AX queries hit it — querying too
    /// early returns stale results.
    private func installWakeReattach() {
        didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                launcherLog.notice("System wake — re-validating docked sessions via reattachAll")
                await self.reattachAll()
            }
        }
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

    /// Re-binds and re-docks every session whose underlying claude
    /// process is still alive. Called once at hub startup so adopted
    /// (and hub-launched) sessions whose pid survived a hub restart
    /// come back as live tabs instead of zombie closed rows.
    func reattachAll() async {
        // Catch the "hub thought it died, but claude is actually alive"
        // case first — typically happens after a spurious close (destroy
        // event during sleep/wake, false-positive lifecycle poll) or
        // when the user re-runs `claude --resume <id>` externally after
        // the hub gave up on it. Promotes those records back to .idle
        // so the reattach loop below can bind them like anything else.
        reconcileStaleClosedSessions()

        // Snapshot to avoid iterating while sessions get mutated.
        let candidates = store.sessions.filter { $0.status.isRunning && $0.pid != nil }
        for session in candidates {
            await reattach(session)
        }
        // Reconcile the SwiftUI selection with DockController's active.
        // SessionStore may have restored a selectedSessionID from
        // UserDefaults; if that session is among the ones we just
        // docked, make it the dock's active too (otherwise the last
        // session iterated above wins by default, since dock() sets
        // activeSessionID on every call). If there's no persisted
        // selection, fall back to whatever ended up active.
        if let persistedID = store.selectedSessionID,
           dockController.dockedSessionIDs.contains(persistedID) {
            dockController.setActiveSessionID(persistedID)
        } else if store.selectedSessionID == nil,
                  let activeID = dockController.activeSessionID {
            store.selectedSessionID = activeID
        }
    }

    /// Walk `~/.claude/sessions/` for live claude processes and, for
    /// each one whose sessionId matches a stored Session marked
    /// `.closed`, promote that Session back to `.idle` with the live
    /// pid. `reattachAll`'s main loop then picks it up like any other
    /// running session.
    ///
    /// Handles two related situations:
    ///   1. Hub gave up on a session (spurious destroy during sleep/
    ///      wake, lifecycle poll false-positive) but the claude
    ///      process actually survived.
    ///   2. User externally ran `claude --resume <id>` after the hub
    ///      had marked the record closed — new pid, same claudeSessionId,
    ///      hub had no way to know.
    private func reconcileStaleClosedSessions() {
        // Build sessionId → live pid map. Filter to interactive/cli
        // like ExternalSessionScanner does; background / plugin
        // sessions can share sessionIds with interactive ones in some
        // configurations and we don't want to adopt those.
        var livePIDBySessionId: [String: pid_t] = [:]
        for file in ClaudeSessionFile.enumerateAll() {
            guard let pid = file.pid, kill(pid_t(pid), 0) == 0 || errno == EPERM else { continue }
            if let kind = file.kind, kind != "interactive" { continue }
            if let entry = file.entrypoint, entry != "cli" { continue }
            livePIDBySessionId[file.sessionId] = pid_t(pid)
        }
        guard !livePIDBySessionId.isEmpty else { return }

        for session in store.sessions
            where session.status == .closed
            && session.claudeSessionId != nil {
            guard let claudeSessionId = session.claudeSessionId,
                  let pid = livePIDBySessionId[claudeSessionId] else { continue }
            store.update(id: session.id) {
                $0.status = .idle
                $0.pid = pid
            }
            launcherLog.notice("Reconciled stale-closed session \(session.id, privacy: .public) — claude pid \(pid, privacy: .public) is alive with the same sessionId")
        }
    }

    /// A reattach failure is terminal only if the claude process is
    /// actually gone. During sleep/wake the host's AppleScript and AX
    /// can briefly fail to resolve a window for a still-alive session;
    /// closing it then would be a false positive that loses the docked
    /// session. `kill(pid, 0)` is the canonical liveness probe.
    private func closeSessionIfProcessDead(_ session: Session, pid: pid_t) {
        let dead = kill(pid, 0) != 0 && errno != EPERM
        if dead {
            store.update(id: session.id) {
                $0.status = .closed
                $0.pid = nil
                $0.hostWindowID = nil
            }
        } else {
            launcherLog.notice("reattach: pid \(pid, privacy: .public) alive but no window resolved yet (likely transient wake state) — leaving session for a later retry")
        }
    }

    @discardableResult
    private func reattach(_ session: Session) async -> Bool {
        guard let pid = session.pid else { return false }
        guard let match = HostWindowResolver.resolve(
            claudePID: pid,
            registry: hostRegistry
        ) else {
            closeSessionIfProcessDead(session, pid: pid)
            return false
        }

        // Lookup order:
        //   1. Persisted Session.hostWindowID — the breadcrumb from the
        //      last successful bind. Synchronous probe (no polling) so
        //      a stale id doesn't burn 3s before falling through.
        //   2. match.cgWindowID — freshly resolved by HostWindowResolver
        //      via the claude process's controlling tty. Only set for
        //      tty-routable hosts (iTerm2, Terminal).
        //   3. The host app's focused window, then its first window —
        //      last resort. May cross-wire to a sibling's window if the
        //      user has multiple windows in the same host; this is the
        //      "wrong window after restart" failure mode we're guarding
        //      against by trying (1) first.
        let window: AXUIElement
        if let preferredID = session.hostWindowID,
           let exact = AXSupport.findWindow(matching: preferredID, in: match.hostAppPID) {
            window = exact
        } else if let cgID = match.cgWindowID,
                  let exact = await AXSupport.waitForWindow(matching: cgID, in: match.hostAppPID) {
            window = exact
        } else if let fallback = focusedWindow(of: match.hostAppPID)
                ?? AXSupport.windows(of: match.hostAppPID).first {
            window = fallback
        } else {
            closeSessionIfProcessDead(session, pid: pid)
            return false
        }

        bindAndPersist(window: window, to: session.id)
        dockController.dock(
            window: window,
            sessionID: session.id,
            hostID: match.hostID,
            tabID: match.tabIdentifier
        )
        return true
    }

    /// Adopts a historical (closed, non-hub-launched) session
    /// discovered on disk by `HistoricalSessionScanner` and immediately
    /// resumes it through the chosen host. Creates a Session record with
    /// `status: .closed` so the existing `resume(_:)` path runs unchanged
    /// — it handles the JSONL-exists check, sets `lastActivityAt`, and
    /// flips status to `.idle` on launch. The record stays in the store
    /// regardless of resume success (consistent with hub-launched closed
    /// sessions); the user can remove it via right-click if a resume
    /// failure makes it unwanted.
    @discardableResult
    func adoptHistorical(
        _ historical: HistoricalSession,
        hostID: String,
        windowMode: WindowMode = .newWindow,
        targetSessionID: Session.ID? = nil
    ) async -> Bool {
        guard hostRegistry.host(forID: hostID) != nil else {
            presentError(LauncherError.unknownHost(hostID))
            return false
        }
        let session = Session(
            name: nil,
            cwd: historical.cwd,
            hostID: hostID,
            claudeSessionId: historical.claudeSessionId,
            status: .closed,
            lastActivityAt: historical.lastActivityAt
        )
        store.add(session)
        return await resume(session, windowMode: windowMode, targetSessionID: targetSessionID)
    }

    /// Adopts an external claude session — one running on the
    /// machine that the hub didn't launch. Resolves the host window
    /// via `HostWindowResolver` (parent-walk first, falling back to
    /// controlling-tty AppleScript for iTerm2/Terminal), creates a
    /// Session record, binds, and docks.
    @discardableResult
    func adopt(_ external: ExternalSession) async -> Bool {
        // Re-resolve at adopt time: the scanner's match may be stale
        // (windows opened/closed since the last poll) and resolution
        // is cheap enough.
        guard let match = HostWindowResolver.resolve(
            claudePID: external.pid,
            registry: hostRegistry
        ) else {
            presentError(LauncherError.launchFailed(
                "Couldn't find which host app this session is running in. " +
                "If you're using a host that isn't in the hub's Settings → " +
                "Hosts list, add it there first. Otherwise the host's process " +
                "tree may not be walkable — try focusing the right window " +
                "and adopting again."
            ))
            return false
        }

        // Prefer the CGWindowID from the tty-based lookup when we
        // have it — that's an exact-window match. Fall back to the
        // host's focused window when we only know the host's PID
        // (parent-walk path).
        let window: AXUIElement
        if let cgID = match.cgWindowID,
           let exact = await AXSupport.waitForWindow(matching: cgID, in: match.hostAppPID) {
            window = exact
        } else if let fallback = focusedWindow(of: match.hostAppPID)
                ?? AXSupport.windows(of: match.hostAppPID).first {
            window = fallback
        } else {
            presentError(LauncherError.windowNotFound(
                "No accessible window found for the host app. Make sure " +
                "Accessibility access is granted."
            ))
            return false
        }

        let session = Session(
            name: external.cwd.lastPathComponent,
            cwd: external.cwd,
            hostID: match.hostID,
            status: .idle
        )
        store.add(session)
        store.update(id: session.id) {
            $0.claudeSessionId = external.claudeSessionId
            $0.pid = external.pid
        }
        bindAndPersist(window: window, to: session.id)
        dockController.dock(
            window: window,
            sessionID: session.id,
            hostID: match.hostID,
            tabID: match.tabIdentifier
        )
        store.selectedSessionID = session.id
        return true
    }

    /// Binds the window in WindowManager and mirrors its CGWindowID
    /// into the persisted Session record. The CGWindowID is the
    /// recovery breadcrumb used by `reattach(_:)` after a hub restart:
    /// transient AX bindings don't survive the restart, but the
    /// underlying window does, and `Session.hostWindowID` lets us
    /// find it again without falling back to the host's "first
    /// window" — which would cross-wire to a sibling session if the
    /// user has multiple windows in the same host.
    private func bindAndPersist(window: AXUIElement, to sessionID: Session.ID) {
        windowManager.bind(window, to: sessionID)
        let windowID = AXSupport.windowID(of: window)
        store.update(id: sessionID) { $0.hostWindowID = windowID }
    }

    /// Returns the AX-focused window of the given app, or nil if AX
    /// can't read it — or if what it returns isn't actually a window.
    /// The role check matters during sleep/wake: the AX server can
    /// hand back the application element for kAXFocusedWindow while
    /// the host is mid-restoration, and binding that produces a
    /// live-but-unraisable session (role reads succeed, window ops
    /// come back Unsupported).
    private func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard err == .success, let element = value else { return nil }
        let window = element as! AXUIElement
        guard AXSupport.role(of: window) == (kAXWindowRole as String) else { return nil }
        return window
    }

    // MARK: - Launcher dispatch

    /// Every host runs through the same launcher. The host's behavior
    /// lives in its `.applescript` file on disk, not in code.
    private func makeLauncher(for config: HostConfig) throws -> SessionLauncher {
        guard let scriptURL = hostRegistry.scriptURL(forID: config.id) else {
            throw LauncherError.unknownHost(config.id)
        }
        return ScriptedHostLauncher(config: config, scriptURL: scriptURL)
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

        bindAndPersist(window: window, to: sessionID)
        // Auto-dock newly-launched sessions. The DockController writes
        // the AX frame into the hub's dock rectangle and pins it there.
        // tabID is filled in below once we've identified the claude
        // pid — without it, hub-tab switching for sessions that share
        // a host window (newTab mode) wouldn't switch the host's
        // internal tab.
        let hostIDForDock = store.sessions.first(where: { $0.id == sessionID })?.hostID ?? ""
        dockController.dock(window: window, sessionID: sessionID, hostID: hostIDForDock)

        if let claudePID = await waitForNewClaudePID(baseline: baselinePIDs) {
            store.update(id: sessionID) { $0.pid = claudePID }
            // Capture the tab identifier (controlling tty) so a later
            // tab-switch in the hub can also flip the host's internal
            // tab via HostTabSelector. Critical for newTab launches
            // that share a host window with sibling sessions.
            if let tty = ProcessTree.controllingTTY(of: claudePID) {
                dockController.setTabID(sessionID: sessionID, tabID: tty)
            }
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
