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
