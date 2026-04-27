import CoreGraphics
import Foundation

/// Returned from a launcher after spawning a session. The marker is the
/// custom title we set on the host's tab so AX-based discovery can find
/// the right window. Session record creation is the service's job — the
/// launcher only knows about the host-specific spawning step.
struct LaunchResult {
    let marker: String
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
    case unsupportedStrategy(String)
    case launchFailed(String)
    case windowNotFound(String)
    case targetWindowMissing
    case missingClaudeSessionId
    case unknownHost(String)

    var errorDescription: String? {
        switch self {
        case .hostNotInstalled(let name):
            return "\(name) is not installed."
        case .unsupportedStrategy(let detail):
            return "This host's launch strategy isn't supported yet: \(detail)."
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
