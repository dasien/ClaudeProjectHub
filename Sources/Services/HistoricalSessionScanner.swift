import Combine
import Darwin
import Foundation

/// Walks `~/.claude/projects/<encoded-cwd>/` to surface closed conversations
/// the hub doesn't already track. The user adopts one through the sidebar's
/// "Available to Resume" section, which then runs through the existing
/// `claude --resume <id>` flow against a host of their choosing.
///
/// Two paths per project dir:
///   1. Preferred: read `sessions-index.json` (claude-written manifest).
///      Gives us `projectPath` (real undecoded cwd), `messageCount`,
///      `summary`/`firstPrompt`, `gitBranch` in one cheap JSON read.
///   2. Fallback: glob `*.jsonl`, use file mtime + decoded dir name. The
///      decoded path is lossy (claude maps every non-alphanumeric to `-`,
///      so `bwcli-rs` is ambiguous) but it's a display hint, not a path
///      we navigate to — the JSONL filename is the authoritative sessionId.
///
/// Excludes:
///   - `claudeSessionId`s already present in `SessionStore.sessions`
///     (any status — hub-launched sessions live there forever)
///   - `claudeSessionId`s belonging to currently-live processes per
///     `ClaudeSessionFile.enumerateAll()`; those are surfaced by
///     `ExternalSessionScanner` as "Available to Dock" instead
///   - Entries with `messageCount == 0` (empty conversation — claude
///     assigns a sessionId at startup but only writes the JSONL once a
///     message is exchanged, so these can't be resumed)
@MainActor
final class HistoricalSessionScanner: ObservableObject {
    @Published private(set) var sessions: [HistoricalSession] = []

    private let store: SessionStore
    private let dismissedStore: DismissedHistoricalStore
    private var timer: Timer?
    private var dismissedCancellable: AnyCancellable?

    init(store: SessionStore, dismissedStore: DismissedHistoricalStore) {
        self.store = store
        self.dismissedStore = dismissedStore
        // Re-scan whenever the dismissed set changes so a "Remove from
        // List" tap takes effect immediately rather than waiting for
        // the 10s timer. `.dropFirst()` skips the initial publish at
        // subscription time; `Task { @MainActor in … }` defers the
        // scan until after the new value has been committed (else
        // currentSkipSet() would still read the old set).
        dismissedCancellable = dismissedStore.$ids
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.scan() }
            }
    }

    /// Begin polling. Slower cadence than `ExternalSessionScanner` (10s
    /// vs 3s) because historical state changes much less frequently —
    /// new entries only appear when a session closes or claude is run
    /// outside the hub.
    func start() {
        guard timer == nil else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Force a scan. Use after adopting so the list updates immediately
    /// rather than waiting for the next poll tick.
    func refresh() {
        scan()
    }

    private func scan() {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            sessions = []
            return
        }

        let skipIds = currentSkipSet()
        var collected: [HistoricalSession] = []
        // Track every sessionId we *saw* on disk in this pass (whether
        // it ends up surfaced or filtered). Used below to prune the
        // dismissed-ids file of entries whose JSONL has been removed
        // — otherwise a Reset-Hidden in Settings wouldn't bring them
        // back, but the file would still record them forever.
        var seenIds: Set<String> = []
        for projectDir in projectDirs where projectDir.hasDirectoryPath {
            let result = scan(projectDir: projectDir, skipping: skipIds)
            collected.append(contentsOf: result.surfaced)
            seenIds.formUnion(result.seen)
        }
        // Only republish on an actual change — see the same guard in
        // ExternalSessionScanner. Historical entries change rarely, so
        // without this the sidebar was being invalidated every 10s for
        // nothing.
        let next = collected.sorted { $0.lastActivityAt > $1.lastActivityAt }
        if next != sessions {
            sessions = next
        }

        // Cleanup: any dismissed id no longer present on disk gets
        // dropped from the dismissed set. Cheap — set subtraction +
        // a JSON write only when something actually changed.
        let stale = dismissedStore.ids.subtracting(seenIds)
        if !stale.isEmpty {
            dismissedStore.restore(stale)
        }
    }

    /// Union of (a) sessionIds the hub already tracks, (b) sessionIds
    /// belonging to currently-running claude processes, and (c)
    /// sessionIds the user has explicitly dismissed. (a) and (b)
    /// belong elsewhere in the UI; (c) is the "Remove from List"
    /// affordance.
    private func currentSkipSet() -> Set<String> {
        var skip: Set<String> = []
        for s in store.sessions {
            if let id = s.claudeSessionId { skip.insert(id) }
        }
        for file in ClaudeSessionFile.enumerateAll() {
            if let pid = file.pid, pidIsAlive(pid_t(pid)) {
                skip.insert(file.sessionId)
            }
        }
        skip.formUnion(dismissedStore.ids)
        return skip
    }

    /// Scans one project directory.
    /// - Returns: `surfaced` = rows the sidebar should display (filtered
    ///   by `skipIds`); `seen` = every sessionId encountered on disk in
    ///   this dir regardless of filter status, used by the caller to
    ///   prune stale dismissed-ids.
    private func scan(projectDir: URL, skipping skipIds: Set<String>) -> (surfaced: [HistoricalSession], seen: Set<String>) {
        var surfaced: [HistoricalSession] = []
        var seen: Set<String> = []

        let indexURL = projectDir.appendingPathComponent("sessions-index.json")
        if let entries = try? readIndex(indexURL) {
            for entry in entries {
                seen.insert(entry.sessionId)
                guard !skipIds.contains(entry.sessionId),
                      entry.messageCount >= 1,
                      entry.isSidechain != true else { continue }
                let cwd: URL
                if let projectPath = entry.projectPath, !projectPath.isEmpty {
                    cwd = URL(fileURLWithPath: projectPath)
                } else {
                    cwd = decodeProjectsDirName(projectDir.lastPathComponent)
                }
                let summary = (entry.summary?.isEmpty == false ? entry.summary : entry.firstPrompt)
                surfaced.append(HistoricalSession(
                    claudeSessionId: entry.sessionId,
                    cwd: cwd,
                    lastActivityAt: Date(timeIntervalSince1970: TimeInterval(entry.fileMtime) / 1000.0),
                    messageCount: entry.messageCount,
                    summary: summary,
                    gitBranch: entry.gitBranch
                ))
            }
            return (surfaced, seen)
        }

        // Fallback for dirs without an index. The size check is a stand-in
        // for messageCount: a JSONL with only the boilerplate first
        // line(s) and no user message is well under 1 KB.
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: projectDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return (surfaced, seen) }
        let decodedCwd = decodeProjectsDirName(projectDir.lastPathComponent)
        for url in contents where url.pathExtension == "jsonl" {
            let sessionId = url.deletingPathExtension().lastPathComponent
            seen.insert(sessionId)
            guard !skipIds.contains(sessionId) else { continue }
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = attrs?.fileSize ?? 0
            guard size > 1024 else { continue }
            surfaced.append(HistoricalSession(
                claudeSessionId: sessionId,
                cwd: decodedCwd,
                lastActivityAt: attrs?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                messageCount: 1,
                summary: nil,
                gitBranch: nil
            ))
        }
        return (surfaced, seen)
    }

    // MARK: - sessions-index.json

    private struct IndexFile: Decodable {
        let version: Int?
        let entries: [IndexEntry]
    }

    /// Schema verified empirically 2026-05-26 against claude 2.1.x.
    /// Fields beyond `sessionId`, `fileMtime`, `messageCount` are
    /// optional in case claude versions vary it.
    private struct IndexEntry: Decodable {
        let sessionId: String
        let fileMtime: Int64
        let messageCount: Int
        let firstPrompt: String?
        let summary: String?
        let gitBranch: String?
        let projectPath: String?
        let isSidechain: Bool?
    }

    private func readIndex(_ url: URL) throws -> [IndexEntry] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(IndexFile.self, from: data).entries
    }

    // MARK: - dir-name decode (fallback only)

    /// Best-effort reverse of claude's projects-dir encoding (every
    /// non-alphanumeric becomes `-`). Lossy and only used as a display
    /// hint when no `sessions-index.json` is available.
    private func decodeProjectsDirName(_ encoded: String) -> URL {
        let stripped = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let path = "/" + stripped.replacingOccurrences(of: "-", with: "/")
        return URL(fileURLWithPath: path)
    }

    private func pidIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
