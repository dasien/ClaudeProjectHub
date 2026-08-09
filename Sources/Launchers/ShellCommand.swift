import Foundation

/// Shell-string helpers. Scripts handle their own `cd` (via AppleScript's
/// `quoted form of`), so all the hub needs to provide is the `claude`
/// invocation itself.
enum ShellCommand {
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds the `claude` invocation, quoting any extra arguments. With no
    /// args and no env, returns just `claude`. Substituted into scripts as
    /// `{claude}`.
    ///
    /// `env` becomes a `VAR=value` prefix rather than an exported variable,
    /// so it applies to this invocation only and works identically whether
    /// the script runs the result via `do shell script` or types it into a
    /// terminal. Sorted so the output is stable.
    static func claudeInvocation(args: [String], env: [String: String] = [:]) -> String {
        var parts = env.sorted { $0.key < $1.key }.map { "\($0.key)=\(quote($0.value))" }
        parts.append("claude")
        parts.append(contentsOf: args.map { quote($0) })
        return parts.joined(separator: " ")
    }
}
