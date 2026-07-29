import Foundation

/// How a new session's host window should be created relative to existing
/// host windows. Substituted into the host's `.applescript` as `{mode}` by
/// `ScriptedHostLauncher`.
enum WindowMode: String, Codable, CaseIterable, Identifiable {
    case newWindow
    case newTab

    var id: String { rawValue }

    var displayName: String {
        switch self {
        // Deliberately host-agnostic: the chosen host is already shown in
        // the dialog's Host dropdown, and "New Terminal window" read as
        // Terminal.app even when launching iTerm2/VSCode/etc.
        case .newWindow: return "New window"
        case .newTab: return "New tab in front window"
        }
    }
}
