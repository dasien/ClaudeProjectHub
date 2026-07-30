import Combine
import Darwin
import Dispatch
import Foundation
import os.log

private let log = Logger(subsystem: "com.bgentry.ClaudeProjectHub", category: "Lifecycle")

/// Watches each running session's `claude` process and the per-process
/// metadata file Claude writes at `~/.claude/sessions/<pid>.json`.
///
/// Process death is **event-driven**: one `DispatchSourceProcess` per
/// running session (kqueue `EVFILT_PROC` / `NOTE_EXIT` underneath)
/// fires the moment the pid exits, so the session flips to `.closed`
/// immediately. This matters for perceived responsiveness — the tab bar
/// and sidebar "inactive" state are driven by `status.isRunning`, so
/// before this they lagged the actual window closing by up to a full
/// poll interval.
///
/// The 2s poll remains for the things that genuinely need sampling:
/// - busy/idle refinement from the per-pid sessions file (no event for it)
/// - re-deriving a missing `tabID` (launch-time tty race)
/// - a liveness backstop, in case a watcher failed to install
///
/// Also exposes an explicit `close` for the right-click action.
@MainActor
final class SessionLifecycleMonitor: ObservableObject {
    private let store: SessionStore
    private let windowManager: WindowManager
    private let dockController: DockController
    private var monitorTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// One exit watcher per running session. Keyed by session id and
    /// tagged with the pid it watches so a session that comes back on a
    /// *different* pid (reconcile promoting a stale-closed record) gets
    /// its watcher rebuilt rather than silently watching a dead pid.
    private var exitWatchers: [Session.ID: (pid: pid_t, source: DispatchSourceProcess)] = [:]

    init(store: SessionStore, windowManager: WindowManager, dockController: DockController) {
        self.store = store
        self.windowManager = windowManager
        self.dockController = dockController
    }

    /// Subscribes to session changes; starts polling when any session is
    /// running and stops when none are, and keeps the per-process exit
    /// watchers in sync. Idempotent — safe to call once at app launch.
    func start() {
        guard cancellables.isEmpty else { return }
        // No Task hop needed here, unlike the watcher subscription
        // below — and the difference is deliberate. `@Published` fires
        // on willSet, but the *emitted value* is the post-mutation one;
        // only reading the property inside a sink yields stale state
        // (verified empirically). This closure derives `hasRunning`
        // purely from the emitted array, so it sees the last session
        // close and stops the poll correctly.
        store.$sessions
            .map { sessions in sessions.contains { $0.status.isRunning } }
            .removeDuplicates()
            .sink { [weak self] hasRunning in
                if hasRunning {
                    self?.startPolling()
                } else {
                    self?.stopPolling()
                }
            }
            .store(in: &cancellables)

        // Separate subscription (no removeDuplicates) because watchers
        // track *which* pids are running, not just whether any are.
        // This one DOES need the Task hop: syncExitWatchers reads
        // `store.sessions` directly rather than the emitted value, and
        // inside a willSet-timed sink that property is still the old
        // array. The defer also lets syncExitWatchers mutate the store
        // (markClosed for an already-exited pid) without re-entering.
        store.$sessions
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncExitWatchers() }
            }
            .store(in: &cancellables)
        syncExitWatchers()
    }

    /// Creates/tears down exit watchers so they exactly match the set of
    /// running sessions that have a pid.
    private func syncExitWatchers() {
        var wanted: [Session.ID: pid_t] = [:]
        for session in store.sessions where session.status.isRunning {
            if let pid = session.pid { wanted[session.id] = pid }
        }

        // Drop watchers whose session stopped running or changed pid.
        for (id, existing) in exitWatchers where wanted[id] != existing.pid {
            existing.source.cancel()
            exitWatchers.removeValue(forKey: id)
        }

        for (id, pid) in wanted where exitWatchers[id] == nil {
            // A source created against an already-dead pid may never
            // fire, so handle that synchronously instead of installing a
            // watcher that would wait forever.
            guard kill(pid, 0) == 0 || errno == EPERM else {
                markClosed(sessionID: id, reason: "pid \(pid) had already exited")
                continue
            }
            let source = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.markClosed(sessionID: id, reason: "process \(pid) exited")
                }
            }
            source.resume()
            exitWatchers[id] = (pid: pid, source: source)
        }
    }

    /// Flips a session to `.closed` and releases what it held. Idempotent
    /// — guards on the session still being running, so the poll backstop
    /// and the exit watcher racing each other is harmless.
    private func markClosed(sessionID: Session.ID, reason: String) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              session.status.isRunning else { return }
        log.notice("Session \(sessionID, privacy: .public) → closed: \(reason, privacy: .public)")
        store.update(id: sessionID) {
            $0.status = .closed
            $0.pid = nil
            $0.hostWindowID = nil
            $0.lastActivityAt = Date()
        }
        windowManager.unbind(sessionID)
        if let existing = exitWatchers.removeValue(forKey: sessionID) {
            existing.source.cancel()
        }
    }

    func close(_ sessionID: Session.ID) {
        windowManager.close(sessionID)
        store.update(id: sessionID) {
            $0.status = .closed
            $0.pid = nil
            $0.hostWindowID = nil
            $0.lastActivityAt = Date()
        }
    }

    private func startPolling() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopPolling() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func poll() {
        for session in store.sessions where session.status.isRunning {
            guard let pid = session.pid else { continue }

            // Liveness backstop. The per-session DispatchSourceProcess
            // watcher normally reports the exit immediately; this only
            // catches a session whose watcher failed to install.
            // kill(pid, 0) is the canonical "is this PID alive" check: it
            // performs error checking but sends no signal. Returns 0 if the
            // process exists, -1 (errno = ESRCH) if not.
            if kill(pid, 0) != 0 {
                markClosed(sessionID: session.id, reason: "pid \(pid) gone (detected by poll backstop)")
                continue
            }

            // Process is alive — self-heal tab routing if it's missing.
            // ProcessTree.controllingTTY(of:) can return nil at launch
            // time if it's called before the kernel has assigned a
            // controlling tty to the new claude process. When that
            // happens, DockController never gets a tabID for the
            // session and `selectActiveTab()` early-returns forever —
            // multi-tab hosts (iTerm2, Terminal) will raise the host's
            // window but stay on whichever tab was already front.
            // Catch the miss here by re-deriving on every poll cycle
            // for docked-but-tab-id-less sessions. Idempotent for
            // sessions that already have a tabID (we don't re-derive).
            if !dockController.hasTabID(forSession: session.id) {
                // Say why the heal didn't happen — a silently-skipped
                // heal leaves the session permanently unable to switch
                // tabs, which is indistinguishable from "no heal needed"
                // in the logs.
                let dockedCount = dockController.dockedSessionIDs.count
                if !dockController.dockedSessionIDs.contains(session.id) {
                    // Expected for any deliberately-undocked session, and
                    // it repeats every poll — .debug so it doesn't drown
                    // the log, but still available when investigating.
                    log.debug("tabID heal skipped for \(session.id, privacy: .public) — not in dockedSessionIDs (docked=\(dockedCount, privacy: .public))")
                } else if let tty = ProcessTree.controllingTTY(of: pid) {
                    dockController.setTabID(sessionID: session.id, tabID: tty)
                    log.notice("Self-healed missing tabID for pid \(pid, privacy: .public) (tty=\(tty, privacy: .public))")
                } else {
                    log.notice("tabID heal skipped for \(session.id, privacy: .public) — ProcessTree.controllingTTY(of: \(pid, privacy: .public)) returned nil")
                }
            }

            // Refine status from Claude's per-process file.
            guard let file = ClaudeSessionFile.read(pid: pid) else { continue }
            let newStatus: SessionStatus = (file.status == "busy") ? .working : .idle
            let newActivity: Date? = file.updatedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000.0)
            }

            let statusChanged = session.status != newStatus
            let activityIsNewer = newActivity.map { $0 > session.lastActivityAt } ?? false
            guard statusChanged || activityIsNewer else { continue }

            store.update(id: session.id) {
                $0.status = newStatus
                if let date = newActivity, date > $0.lastActivityAt {
                    $0.lastActivityAt = date
                }
            }
        }
    }
}
