import Foundation

/// How a new session's host window should be created relative to existing
/// host windows. Currently consumed by `TerminalAppLauncher`; other hosts
/// can adopt the same enum.
enum WindowMode: String, Codable, CaseIterable, Identifiable {
    case newWindow
    case newTab

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newWindow: return "New Terminal window"
        case .newTab: return "New tab in front window"
        }
    }
}
