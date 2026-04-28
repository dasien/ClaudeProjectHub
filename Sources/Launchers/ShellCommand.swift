import Foundation

/// Shell-string helpers. Scripts handle their own `cd` (via AppleScript's
/// `quoted form of`), so all the hub needs to provide is the `claude`
/// invocation itself.
enum ShellCommand {
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds the `claude` invocation, quoting any extra arguments. With no
    /// args, returns just `claude`. Substituted into scripts as `{claude}`.
    static func claudeInvocation(args: [String]) -> String {
        guard !args.isEmpty else { return "claude" }
        let escaped = args.map { quote($0) }.joined(separator: " ")
        return "claude \(escaped)"
    }
}
