import ApplicationServices
import CoreGraphics
import Foundation

/// Returned from a launcher after spawning a session. The launcher passes
/// back enough info for the service to find the new host window via AX.
///
/// Two discovery paths are supported:
/// - `marker` only: service searches AX windows for one whose title contains
///   the marker. Works when the host (e.g. Terminal) makes our custom title
///   visible in its AX window title.
/// - `preDiscoveredWindow` set: launcher already located the AX window
///   itself (e.g. via pre/post window-set diff for iTerm2, where AX titles
///   don't reflect our AppleScript-set session name). Service uses it
///   directly and skips the marker search.
struct LaunchResult {
    let marker: String
    let preDiscoveredWindow: AXUIElement?

    init(marker: String, preDiscoveredWindow: AXUIElement? = nil) {
        self.marker = marker
        self.preDiscoveredWindow = preDiscoveredWindow
    }
}

protocol SessionLauncher {
    func isAvailable() -> Bool
    func launch(
        in cwd: URL,
        mode: WindowMode,
        targetWindowID: CGWindowID?,
        claudeArgs: [String]
    ) async throws -> LaunchResult
}

enum LauncherError: Error, LocalizedError {
    case hostNotInstalled(String)
    case launchFailed(String)
    case windowNotFound(String)
    case targetWindowMissing
    case missingClaudeSessionId
    case unknownHost(String)

    var errorDescription: String? {
        switch self {
        case .hostNotInstalled(let name):
            return "\(name) is not installed."
        case .launchFailed(let detail):
            return "Launch failed: \(detail)"
        case .windowNotFound(let detail):
            return "Could not locate launched window: \(detail)"
        case .targetWindowMissing:
            return "The selected target session's window is no longer available. Pick a different session or use \"New window\"."
        case .missingClaudeSessionId:
            return "This session doesn't have a Claude session ID captured, so it can't be resumed. Start a new session in the same directory instead."
        case .unknownHost(let id):
            return "No host configured with id \"\(id)\". Check ~/Library/Application Support/ClaudeProjectHub/hosts.json."
        }
    }
}
