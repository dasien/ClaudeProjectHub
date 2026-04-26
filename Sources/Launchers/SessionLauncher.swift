import CoreGraphics
import Foundation

struct LaunchResult {
    let session: Session
    let marker: String
}

protocol SessionLauncher {
    var hostKind: HostKind { get }
    func isAvailable() -> Bool
    func launch(
        in cwd: URL,
        mode: WindowMode,
        targetWindowID: CGWindowID?
    ) async throws -> LaunchResult
}

enum LauncherError: Error, LocalizedError {
    case hostNotInstalled(String)
    case launchFailed(String)
    case windowNotFound(String)
    case targetWindowMissing

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
        }
    }
}
