import Foundation

/// Disk-backed cache of parsed JSONL transcript usage, keyed by the
/// JSONL's (path, fileSize, mtime). Lets the dashboard skip the
/// re-parse for any transcript that hasn't been appended to since
/// last seen. JSONLs are append-only in practice, so a (size, mtime)
/// match is a reliable signal that the file's content is identical.
///
/// Persists across hub launches so a cold start is only slow on the
/// first run.
final class TranscriptCache: @unchecked Sendable {
    private struct Key: Hashable, Codable {
        let path: String
        let size: Int64
        let mtime: Date
    }

    private struct StoredEntry: Codable {
        let key: Key
        let usage: SessionUsage
    }

    private var entries: [Key: SessionUsage] = [:]
    private let storeURL: URL
    private let queue = DispatchQueue(label: "transcript-cache", qos: .userInitiated)

    init(storeURL: URL = TranscriptCache.defaultStoreURL) {
        self.storeURL = storeURL
        load()
    }

    /// Return cached usage if the JSONL's current path/size/mtime
    /// match a stored entry. Nil if cold, missing, or file changed.
    func get(for jsonlURL: URL) -> SessionUsage? {
        guard let key = makeKey(for: jsonlURL) else { return nil }
        return queue.sync { entries[key] }
    }

    /// Store a freshly-parsed usage for the JSONL's current state.
    /// Writes the cache to disk on the cache's own queue so callers
    /// don't block on I/O.
    func set(_ usage: SessionUsage, for jsonlURL: URL) {
        guard let key = makeKey(for: jsonlURL) else { return }
        queue.async {
            self.entries[key] = usage
            self.persist()
        }
    }

    private func makeKey(for url: URL) -> Key? {
        guard let attrs = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ),
              let size = attrs.fileSize,
              let mtime = attrs.contentModificationDate
        else { return nil }
        return Key(path: url.path, size: Int64(size), mtime: mtime)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([StoredEntry].self, from: data) else { return }
        entries = Dictionary(uniqueKeysWithValues: stored.map { ($0.key, $0.usage) })
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stored = entries.map { StoredEntry(key: $0.key, usage: $0.value) }
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }

    private static var defaultStoreURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("ClaudeProjectHub", isDirectory: true)
            .appendingPathComponent("transcript-cache.json")
    }
}
