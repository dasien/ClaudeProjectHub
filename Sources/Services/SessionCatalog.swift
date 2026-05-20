import Combine
import Foundation

/// Discovers every claude session known to the machine and builds
/// `DashboardRow` view models for the Sessions Dashboard window.
///
/// Sources, deduped by `claudeSessionId`:
///   1. `SessionStore.sessions` — hub-tracked (live + closed).
///   2. JSONL transcripts under `~/.claude/projects/` whose
///      `claudeSessionId` doesn't match any hub-tracked record.
///      These surface as `.historical` status — process is gone,
///      transcript still on disk.
///
/// Per-session cost requires parsing a JSONL, which is expensive when
/// many transcripts exist. `TranscriptCache` caches results by file
/// path/size/mtime so subsequent dashboard opens skip the re-parse.
///
/// `refresh()` is async because parses run off the main thread.
/// The dashboard surfaces a progress spinner while it works.
@MainActor
final class SessionCatalog: ObservableObject {
    @Published private(set) var rows: [DashboardRow] = []
    @Published private(set) var isLoading: Bool = false

    private let store: SessionStore
    private let hostRegistry: HostRegistry
    private let pricing: ModelPricingRegistry
    private let cache: TranscriptCache

    init(
        store: SessionStore,
        hostRegistry: HostRegistry,
        pricing: ModelPricingRegistry,
        cache: TranscriptCache = TranscriptCache()
    ) {
        self.store = store
        self.hostRegistry = hostRegistry
        self.pricing = pricing
        self.cache = cache
    }

    /// Rebuild the row list from all sources. Parses transcripts off
    /// the main thread (via `Task.detached`) so the UI stays responsive.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        // Hub-tracked first; remember claudeSessionIds so we dedup
        // when walking the on-disk JSONLs in the next step.
        var hubRows: [DashboardRow] = []
        var hubSessionIds: Set<String> = []
        hubRows.reserveCapacity(store.sessions.count)
        for session in store.sessions {
            let usage = await loadUsage(forCwd: session.cwd, claudeSessionId: session.claudeSessionId)
            let cost = usage.totalCost(using: pricing)
            hubRows.append(DashboardRow(
                id: session.id,
                name: session.displayTitle,
                cwd: session.cwd,
                cwdPath: session.cwd.path,
                hostID: session.hostID,
                hostDisplayName: hostRegistry.displayName(forID: session.hostID),
                status: DashboardStatus.from(session.status),
                createdAt: session.createdAt,
                lastActivityAt: session.lastActivityAt,
                cost: cost,
                totalTokens: usage.totalTokens,
                claudeSessionId: session.claudeSessionId
            ))
            if let id = session.claudeSessionId {
                hubSessionIds.insert(id)
            }
        }

        let historicalRows = await loadHistoricalRows(excluding: hubSessionIds)
        rows = hubRows + historicalRows
    }

    /// Parse usage for a hub-tracked session, going through the cache.
    /// Empty `SessionUsage` for sessions with no recorded conversation
    /// (opened then closed without exchanging a message) or when the
    /// parse fails — both are legitimately zero-cost.
    private func loadUsage(forCwd cwd: URL, claudeSessionId: String?) async -> SessionUsage {
        guard let claudeSessionId else { return SessionUsage() }
        let url = ClaudeSessionTranscript.jsonlURL(for: cwd, claudeSessionId: claudeSessionId)
        return await loadUsage(jsonlURL: url)
    }

    private func loadUsage(jsonlURL: URL) async -> SessionUsage {
        if let cached = cache.get(for: jsonlURL) {
            return cached
        }
        let usage = await Task.detached(priority: .userInitiated) {
            (try? ClaudeSessionTranscript.parse(jsonlURL: jsonlURL)) ?? SessionUsage()
        }.value
        cache.set(usage, for: jsonlURL)
        return usage
    }

    /// Walk `~/.claude/projects/<encoded-cwd>/*.jsonl` and build rows
    /// for every transcript whose `claudeSessionId` isn't already
    /// surfaced by the hub. Process is presumed dead; status is
    /// `.historical`. Host is unknown — the per-pid sessions file is
    /// long gone, and the JSONL doesn't record which host launched it.
    private func loadHistoricalRows(excluding knownIds: Set<String>) async -> [DashboardRow] {
        let projectsDir = URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath)
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var rows: [DashboardRow] = []
        for projectDir in projectDirs {
            guard projectDir.hasDirectoryPath else { continue }
            let cwd = decodeEncodedCwd(projectDir.lastPathComponent)
            guard let jsonlURLs = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]
            ) else { continue }
            for jsonlURL in jsonlURLs where jsonlURL.pathExtension == "jsonl" {
                let claudeSessionId = jsonlURL.deletingPathExtension().lastPathComponent
                if knownIds.contains(claudeSessionId) { continue }

                let attrs = try? jsonlURL.resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey]
                )
                let created = attrs?.creationDate ?? .distantPast
                let modified = attrs?.contentModificationDate ?? created

                let usage = await loadUsage(jsonlURL: jsonlURL)
                let cost = usage.totalCost(using: pricing)

                rows.append(DashboardRow(
                    id: UUID(),
                    name: cwd.lastPathComponent,
                    cwd: cwd,
                    cwdPath: cwd.path,
                    hostID: nil,
                    hostDisplayName: "Unknown",
                    status: .historical,
                    createdAt: created,
                    lastActivityAt: modified,
                    cost: cost,
                    totalTokens: usage.totalTokens,
                    claudeSessionId: claudeSessionId
                ))
            }
        }
        return rows
    }

    /// Decode a projects-directory name back to a cwd URL. Encoding
    /// replaces `/` with `-`, so reversing loses information for paths
    /// that contained dashes (`ai-logging` could have been `ai/logging`).
    /// Best-effort — we only need a displayable path here, not one to
    /// navigate to.
    private func decodeEncodedCwd(_ encoded: String) -> URL {
        let stripped = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let path = "/" + stripped.replacingOccurrences(of: "-", with: "/")
        return URL(fileURLWithPath: path)
    }
}
