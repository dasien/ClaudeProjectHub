import Foundation

enum HostKind: String, Codable, CaseIterable, Identifiable {
    case terminalApp = "terminal-app"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminalApp: return "Terminal"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminalApp: return "com.apple.Terminal"
        }
    }
}
