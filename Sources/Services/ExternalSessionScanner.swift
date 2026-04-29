import AppKit
import Darwin
import Foundation

/// One claude session running on the machine that the hub didn't
/// launch. Surfaced in the sidebar's "Available to Dock" section so
/// the user can adopt it.
struct ExternalSession: Identifiable, Hashable {
    /// Stable identity within the UI list — uses claudeSessionId so
    /// the row doesn't churn even if claude restarts and gets a new
    /// pid.
    var id: String { claudeSessionId }

    let claudeSessionId: String
    let pid: pid_t
    let cwd: URL
    /// PID of the host app (Terminal, iTerm2, …) hosting this claude
    /// process. nil if we couldn't resolve it (e.g. the host isn't
    /// in our hosts.json registry).
    let hostAppPID: pid_t?
    /// HostConfig.id for the matched host, or nil. Lets the sidebar
    /// show the right icon and host name.
    let hostID: String?
}

@MainActor
final class ExternalSessionScanner: ObservableObject {
    @Published private(set) var sessions: [ExternalSession] = []

    private let store: SessionStore
    private let hostRegistry: HostRegistry
    private var timer: Timer?

    init(store: SessionStore, hostRegistry: HostRegistry) {
        self.store = store
        self.hostRegistry = hostRegistry
    }

    /// Begin polling. Cheap operation — reads small JSON files in
    /// `~/.claude/sessions/` every few seconds.
    func start() {
        guard timer == nil else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Force a scan. Use after adopting a session so the list updates
    /// immediately rather than waiting for the next poll tick.
    func refresh() {
        scan()
    }

    private func scan() {
        let files = ClaudeSessionFile.enumerateAll()
        // Build a set of pids the hub already tracks so we don't
        // re-list our own sessions as "external."
        let trackedPIDs: Set<pid_t> = Set(store.sessions.compactMap { $0.pid })
        let trackedSessionIds: Set<String> = Set(store.sessions.compactMap { $0.claudeSessionId })

        let candidates: [ExternalSession] = files.compactMap { file in
            guard let pid = file.pid,
                  pidIsAlive(pid_t(pid)),
                  let cwdString = file.cwd else { return nil }

            // Filter out non-interactive / non-CLI variants. The
            // session file format includes background plugin
            // sessions and similar that we don't want to dock.
            if let kind = file.kind, kind != "interactive" { return nil }
            if let entry = file.entrypoint, entry != "cli" { return nil }

            // Skip sessions we already know about — by pid OR by
            // claudeSessionId, so a hub-launched session in any
            // state (running, closed) isn't surfaced as adoptable.
            if trackedPIDs.contains(pid_t(pid)) { return nil }
            if trackedSessionIds.contains(file.sessionId) { return nil }

            let match = HostWindowResolver.resolve(claudePID: pid_t(pid), registry: hostRegistry)
            return ExternalSession(
                claudeSessionId: file.sessionId,
                pid: pid_t(pid),
                cwd: URL(fileURLWithPath: cwdString),
                hostAppPID: match?.hostAppPID,
                hostID: match?.hostID
            )
        }
        self.sessions = candidates.sorted { $0.cwd.lastPathComponent < $1.cwd.lastPathComponent }
    }

    /// `kill(pid, 0)` succeeds if the process exists and we have
    /// permission to signal it. Reasonable proxy for "is alive."
    private func pidIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
