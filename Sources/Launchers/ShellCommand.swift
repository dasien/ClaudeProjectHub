import Foundation

/// Helpers for building shell command strings that survive intact through
/// `do script` / `write text` → AppleScript string literal → bash. Single-
/// quote wrapping is the standard pattern; embedded single quotes are
/// escaped as `'\''`.
enum ShellCommand {
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds the `claude` invocation, quoting any extra arguments. With no
    /// args, returns just `claude`.
    static func claudeInvocation(args: [String]) -> String {
        guard !args.isEmpty else { return "claude" }
        let escaped = args.map { quote($0) }.joined(separator: " ")
        return "claude \(escaped)"
    }

    /// Composes `cd <quoted-cwd> && <claude-invocation>` — the full command
    /// the host needs to run.
    static func cdThenClaude(cwd: URL, args: [String]) -> String {
        "cd \(quote(cwd.path)) && \(claudeInvocation(args: args))"
    }
}
