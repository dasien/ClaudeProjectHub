import Foundation

/// View model for a row in the Sessions Dashboard. Holds pre-resolved
/// display values (host name, total tokens, computed cost, etc.) so
/// the SwiftUI `Table` can render and sort without re-walking the
/// catalog's source data on every layout pass.
struct DashboardRow: Identifiable {
    /// Stable across `SessionCatalog.refresh()` calls, which matters
    /// because `Table` keys its selection and scroll position on it —
    /// historical rows previously got a fresh `UUID()` per refresh, so
    /// every refresh rebuilt them and dropped both. Namespaced by
    /// origin (`session-` / `transcript-`) so a hub session id and a
    /// conversation id can never collide.
    let id: String
    let name: String
    let cwd: URL
    /// Pre-computed `cwd.path` so the Table can sort the column as a
    /// `String` rather than re-deriving on every comparison.
    let cwdPath: String
    let hostID: String?
    /// Resolved at catalog build time via `HostRegistry.displayName`,
    /// so the table doesn't need a `HostRegistry` reference for
    /// rendering. "Unknown" for historical-only rows where the host
    /// wasn't recorded.
    let hostDisplayName: String
    let status: DashboardStatus
    let createdAt: Date
    let lastActivityAt: Date
    /// USD, computed via `SessionUsage.totalCost(using: pricing)`.
    /// Zero for sessions without a recorded transcript.
    let cost: Double
    /// Sum of input + output + cache tokens across all models for the
    /// session.
    let totalTokens: Int
    /// Conversation id (JSONL filename). Used for dedup across
    /// discovery sources (hub-tracked vs historical).
    let claudeSessionId: String?
}

/// Status as the dashboard surfaces it. Mirrors `SessionStatus` plus
/// a new `.historical` case for sessions whose process is gone but
/// transcript still exists on disk. Kept separate from the main
/// `SessionStatus` enum so adding `.historical` doesn't force exhaustive
/// switch updates across the rest of the app.
enum DashboardStatus: String, Hashable, CaseIterable, Identifiable {
    case working = "Working"
    case idle = "Idle"
    case closed = "Closed"
    case historical = "Historical"

    var id: String { rawValue }

    var sortRank: Int {
        switch self {
        case .working: return 0
        case .idle: return 1
        case .closed: return 2
        case .historical: return 3
        }
    }

    /// Map from the main app `SessionStatus` enum. Historical is
    /// dashboard-only; the conversion only goes one way.
    static func from(_ status: SessionStatus) -> DashboardStatus {
        switch status {
        case .working: return .working
        case .idle: return .idle
        case .closed: return .closed
        }
    }
}
