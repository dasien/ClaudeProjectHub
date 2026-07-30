import Foundation

enum AppleScriptError: Error, LocalizedError {
    case compileFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .compileFailed(let message):
            return "AppleScript compile failed: \(message)"
        case .executionFailed(let message):
            return "AppleScript execution failed: \(message)"
        }
    }
}

enum AppleScriptRunner {
    /// Synchronous on the calling thread, which in practice is always
    /// the main actor. A background serial queue was tried here to get
    /// `HostTabSelector` off the click path, but running tab selection
    /// detached broke the raise→select ordering the host depends on —
    /// see the note in `HostTabSelector`. Kept simple until there's a
    /// design that preserves that ordering.
    @discardableResult
    static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError.compileFailed("could not initialize NSAppleScript")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let message = (info[NSAppleScript.errorMessage] as? String) ?? "unknown"
            throw AppleScriptError.executionFailed(message)
        }
        return result
    }
}
