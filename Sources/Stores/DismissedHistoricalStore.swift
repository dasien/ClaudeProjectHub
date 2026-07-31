import Foundation

/// Persistent set of `claudeSessionId`s the user has hidden from the
/// "Available to Resume" section. `HistoricalSessionScanner` reads
/// this and unions it into its skip set so dismissed entries don't
/// reappear on the next scan or hub restart.
///
/// Dismissal only affects the hub's view — the underlying JSONL at
/// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` is never
/// modified. Reset from Settings → General → Hidden Sessions to
/// recover.
@MainActor
final class DismissedHistoricalStore: ObservableObject {
    @Published private(set) var ids: Set<String> = []

    private let storeURL: URL
    private let persists: Bool

    init(storeURL: URL = DismissedHistoricalStore.defaultStoreURL, persists: Bool = true) {
        self.storeURL = storeURL
        self.persists = persists
        load()
    }

    func dismiss(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.insert(id)
        save()
    }

    func dismiss(_ idsToAdd: Set<String>) {
        let new = idsToAdd.subtracting(ids)
        guard !new.isEmpty else { return }
        ids.formUnion(new)
        save()
    }

    /// Used by the undo affordance and by the scanner's cleanup pass
    /// (when a dismissed sessionId's JSONL has been removed from disk).
    func restore(_ idsToRestore: Set<String>) {
        let removable = idsToRestore.intersection(ids)
        guard !removable.isEmpty else { return }
        ids.subtract(removable)
        save()
    }

    func clear() {
        guard !ids.isEmpty else { return }
        ids.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        ids = Set(decoded)
    }

    private func save() {
        guard persists else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Encode as a sorted array rather than a Set so the on-disk
        // file is diff-friendly and human-inspectable.
        guard let data = try? encoder.encode(ids.sorted()) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }

    // nonisolated for the same reason as SessionStore's: it's a default
    // argument in `init` (a nonisolated position) and touches only
    // FileManager.
    nonisolated static var defaultStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("ClaudeProjectHub", isDirectory: true)
            .appendingPathComponent("dismissed-historical.json")
    }
}
