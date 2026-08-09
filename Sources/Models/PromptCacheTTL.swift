import Foundation

/// How long Claude keeps this session's prompt cache warm.
///
/// Claude Code writes 5-minute cache entries by default; setting
/// `ENABLE_PROMPT_CACHING_1H=1` in its environment switches it to the
/// 1-hour tier. The hub can only choose at launch — there's no way to
/// change a running session's TTL.
enum PromptCacheTTL: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveMinutes
    case oneHour

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .oneHour: "1 hour"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .oneHour: 60 * 60
        }
    }

    /// Environment the `claude` process needs. 5m is Claude Code's own
    /// default, so it needs nothing set.
    var environment: [String: String] {
        switch self {
        case .fiveMinutes: [:]
        case .oneHour: ["ENABLE_PROMPT_CACHING_1H": "1"]
        }
    }
}
