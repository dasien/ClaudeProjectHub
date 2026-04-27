import Foundation

enum SessionStatus: String, Codable {
    case idle
    case working
    case closed

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "idle": self = .idle
        case "working": self = .working
        case "closed": self = .closed
        // Backwards-compat: pre-idle/working builds wrote "running" to disk.
        // Treat those as idle on load — the lifecycle monitor will refine
        // them on the next poll if the process is still alive (or close
        // them via the same load-time policy as before).
        case "running": self = .idle
        default: self = .idle
        }
    }
}

extension SessionStatus {
    var isRunning: Bool {
        self == .idle || self == .working
    }

    /// Sidebar sort priority: working sessions float to the top (they
    /// might need attention), then idle, then closed.
    var sortRank: Int {
        switch self {
        case .working: return 0
        case .idle: return 1
        case .closed: return 2
        }
    }
}
