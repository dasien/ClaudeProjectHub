import Foundation
import os

private let log = Logger(subsystem: "com.bgentry.ClaudeProjectHub", category: "Store")

/// Copies a file that failed to decode to `<name>.corrupt-<timestamp>`
/// before anything can save over it. Both stores used to treat a decode
/// failure as "start empty" and then overwrite the file on the next
/// save, so one bad record or a hand-edit typo silently erased every
/// session or custom host.
enum CorruptFile {
    /// - Returns: the backup's URL, or nil if the copy failed — in which
    ///   case the caller must not save over the original.
    static func preserve(_ url: URL, error: Error) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.appendingPathExtension("corrupt-\(stamp)")
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            log.error("\(url.lastPathComponent, privacy: .public) failed to decode (\(String(describing: error), privacy: .public)); original preserved at \(backup.path, privacy: .public)")
            return backup
        } catch {
            log.fault("\(url.lastPathComponent, privacy: .public) failed to decode and could not be backed up (\(error.localizedDescription, privacy: .public)); refusing to overwrite it")
            return nil
        }
    }
}
