import Foundation

/// One previously-closed claude session discovered on disk by
/// `HistoricalSessionScanner`. Surfaced in the sidebar's "Available to
/// Resume" section so the user can pick a host and bring it back via
/// `claude --resume`. Not persisted — rebuilt from `sessions-index.json`
/// / JSONL globs on every scan.
struct HistoricalSession: Identifiable, Hashable {
    /// Stable id for SwiftUI lists — the claude conversation id.
    var id: String { claudeSessionId }

    let claudeSessionId: String
    let cwd: URL
    let lastActivityAt: Date
    let messageCount: Int
    /// First-prompt or summary text from `sessions-index.json`, when
    /// present. Used as a subtitle in the sidebar row so the user has
    /// more than a cwd basename to identify the session by.
    let summary: String?
    let gitBranch: String?
}
