import Darwin
import Foundation

/// Subset of the JSON Claude maintains at `~/.claude/sessions/<pid>.json`,
/// one per running claude process. Fields beyond `sessionId` are optional
/// in case the schema shifts across Claude versions.
struct ClaudeSessionFile: Decodable {
    let sessionId: String
    let pid: Int32?
    let cwd: String?
    let status: String?
    let updatedAt: Int64?
    let kind: String?
    let entrypoint: String?
    let version: String?
}

extension ClaudeSessionFile {
    /// Synchronous single-attempt read. Returns nil if the file doesn't exist
    /// or doesn't decode cleanly. Use this in poll loops.
    static func read(pid: pid_t) -> ClaudeSessionFile? {
        let url = path(for: pid)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data) else {
            return nil
        }
        return file
    }

    /// Polling read — the file may not exist for the first ~200ms after the
    /// claude process starts. Use this immediately after capturing a new PID.
    static func read(pid: pid_t, timeout: TimeInterval) async -> ClaudeSessionFile? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let file = read(pid: pid) {
                return file
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    private static func path(for pid: pid_t) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/\(pid).json")
    }

    /// Returns the directory containing all per-pid session files.
    static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Enumerates every per-pid session JSON in the sessions
    /// directory and decodes each. Stale files (orphaned after a
    /// crash) may be present; callers should filter by pid liveness.
    static func enumerateAll() -> [ClaudeSessionFile] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data) else {
                return nil
            }
            return file
        }
    }
}
