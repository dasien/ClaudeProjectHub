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
    /// Resolved host windows, keyed by claude pid.
    ///
    /// `HostWindowResolver.resolve` asks each running terminal host via
    /// AppleScript which window holds a given tty, and every AppleScript
    /// property access is a separate Apple Event — so one call walks
    /// `windows → tabs → sessions` at real cost. This scanner runs every
    /// 3s forever, which meant an external session the user never
    /// adopted paid that walk ~20 times a minute indefinitely, and up to
    /// twice per tick (iTerm2, then Terminal). A live pid's host window
    /// doesn't change for the life of the process, so resolving once per
    /// pid is enough.
    ///
    /// Only *successes* are cached. A failure usually means claude is in
    /// a host that isn't in the registry, but it can also be transient
    /// (the tty lookup racing a host still starting up), and retrying
    /// costs no more than what we already did. Nothing here can cause a
    /// wrong binding either way: `SessionLauncherService.adopt`
    /// re-resolves from scratch at adopt time, so the worst a stale
    /// entry can do is show an out-of-date host icon in the sidebar.
    private var resolveCache: [pid_t: HostWindowResolver.Match] = [:]

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

        // Live pids up front: used both to filter candidates and to
        // evict resolve-cache entries for processes that have exited, so
        // the cache can't grow across the app's lifetime.
        let livePIDs: Set<pid_t> = Set(
            files.compactMap { file -> pid_t? in
                guard let pid = file.pid, pidIsAlive(pid_t(pid)) else { return nil }
                return pid_t(pid)
            }
        )
        resolveCache = resolveCache.filter { livePIDs.contains($0.key) }

        let candidates: [ExternalSession] = files.compactMap { file in
            guard let pid = file.pid,
                  livePIDs.contains(pid_t(pid)),
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

            let match = resolvedMatch(forClaudePID: pid_t(pid))
            return ExternalSession(
                claudeSessionId: file.sessionId,
                pid: pid_t(pid),
                cwd: URL(fileURLWithPath: cwdString),
                hostAppPID: match?.hostAppPID,
                hostID: match?.hostID
            )
        }
        // Only republish on an actual change. `@Published` fires
        // `objectWillChange` on assignment regardless of equality, and
        // `SessionsSidebar` observes this object — so assigning an
        // identical array every 3s re-ran the whole sidebar body, the
        // session sort, and the full List diff ~20 times a minute while
        // completely idle.
        let next = candidates.sorted { $0.cwd.lastPathComponent < $1.cwd.lastPathComponent }
        guard next != sessions else { return }
        self.sessions = next
    }

    /// Cached `HostWindowResolver.resolve`. See `resolveCache` for why
    /// this is worth caching and why failures aren't cached.
    private func resolvedMatch(forClaudePID pid: pid_t) -> HostWindowResolver.Match? {
        if let cached = resolveCache[pid] { return cached }
        guard let match = HostWindowResolver.resolve(
            claudePID: pid,
            registry: hostRegistry
        ) else { return nil }
        resolveCache[pid] = match
        return match
    }

    /// `kill(pid, 0)` succeeds if the process exists and we have
    /// permission to signal it. Reasonable proxy for "is alive."
    private func pidIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
