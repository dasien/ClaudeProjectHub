import Foundation

/// Disk-backed cache of parsed JSONL transcript usage, keyed by the
/// JSONL's path and validated against its (fileSize, mtime). Lets the
/// dashboard skip the re-parse for any transcript that hasn't been
/// appended to since last seen. JSONLs are append-only in practice, so
/// a (size, mtime) match is a reliable signal that the file's content
/// is identical.
///
/// Persists across hub launches so a cold start is only slow on the
/// first run.
final class TranscriptCache: @unchecked Sendable {
    /// One cached parse. The (size, mtime) stamp lives in the *value*,
    /// not the key — keying by it meant every append to a transcript
    /// inserted a new entry and orphaned the previous one, so the cache
    /// grew by one permanent record per dashboard refresh of any active
    /// session. Keying by path alone caps it at one entry per
    /// transcript and makes `set` an overwrite.
    private struct Entry: Codable {
        let size: Int64
        let mtime: Date
        let usage: SessionUsage
    }

    private struct Stamp {
        let size: Int64
        let mtime: Date
    }

    /// Keyed by JSONL path.
    private var entries: [String: Entry] = [:]
    private let storeURL: URL
    private let queue = DispatchQueue(label: "transcript-cache", qos: .userInitiated)

    init(storeURL: URL = TranscriptCache.defaultStoreURL) {
        self.storeURL = storeURL
        load()
    }

    /// Return cached usage if the JSONL's current size/mtime still match
    /// what was cached for that path. Nil if cold, missing, or changed.
    func get(for jsonlURL: URL) -> SessionUsage? {
        guard let stamp = stamp(for: jsonlURL) else { return nil }
        return queue.sync { () -> SessionUsage? in
            guard let entry = entries[jsonlURL.path],
                  entry.size == stamp.size,
                  entry.mtime == stamp.mtime else { return nil }
            return entry.usage
        }
    }

    /// Store a freshly-parsed usage for the JSONL's current state.
    /// Writes the cache to disk on the cache's own queue so callers
    /// don't block on I/O.
    func set(_ usage: SessionUsage, for jsonlURL: URL) {
        guard let stamp = stamp(for: jsonlURL) else { return }
        queue.async {
            self.entries[jsonlURL.path] = Entry(
                size: stamp.size,
                mtime: stamp.mtime,
                usage: usage
            )
            self.persist()
        }
    }

    private func stamp(for url: URL) -> Stamp? {
        guard let attrs = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ),
              let size = attrs.fileSize,
              let mtime = attrs.contentModificationDate
        else { return nil }
        return Stamp(size: Int64(size), mtime: mtime)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A decode failure includes the pre-path-keyed on-disk format.
        // The cache is purely derived data, so starting cold is a
        // correctness-neutral outcome — one slow dashboard refresh.
        guard let stored = try? decoder.decode([String: Entry].self, from: data) else { return }
        // Drop transcripts that no longer exist, so the file doesn't
        // accumulate records for deleted projects forever.
        entries = stored.filter { FileManager.default.fileExists(atPath: $0.key) }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
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
