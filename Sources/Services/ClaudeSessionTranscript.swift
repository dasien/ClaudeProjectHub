import Foundation

/// Reads a Claude session JSONL transcript and aggregates the token
/// usage. Handles only the fields we care about for cost; ignores
/// content, tool calls, snapshots, and other line types.
///
/// The file lives at `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`.
/// Each line is one JSON object. Lines containing an assistant message
/// have:
///
/// ```
/// {
///   "message": {
///     "model": "claude-opus-4-6",
///     "role": "assistant",
///     "usage": {
///       "input_tokens": 3,
///       "output_tokens": 187,
///       "cache_creation_input_tokens": 6483,
///       "cache_read_input_tokens": 12725,
///       "cache_creation": {
///         "ephemeral_5m_input_tokens": 6483,
///         "ephemeral_1h_input_tokens": 0
///       }
///     }
///   }
/// }
/// ```
///
/// Older transcripts may lack the `cache_creation` breakdown; in
/// that case all `cache_creation_input_tokens` are billed at the
/// 5-minute rate (the cheaper of the two — conservative estimate).
enum ClaudeSessionTranscript {
    enum ParseError: Error {
        case unreadable(URL)
    }

    static func parse(jsonlURL: URL) throws -> SessionUsage {
        guard let data = try? Data(contentsOf: jsonlURL),
              let text = String(data: data, encoding: .utf8) else {
            throw ParseError.unreadable(jsonlURL)
        }
        var usage = SessionUsage()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            accumulate(from: obj, into: &usage)
        }
        return usage
    }

    private static func accumulate(from obj: [String: Any], into usage: inout SessionUsage) {
        // Only assistant messages carry a usage block.
        guard let message = obj["message"] as? [String: Any],
              (message["role"] as? String) == "assistant",
              let usageBlock = message["usage"] as? [String: Any] else {
            return
        }
        let model = (message["model"] as? String) ?? "unknown"
        var totals = usage.byModel[model] ?? .init()

        let input = (usageBlock["input_tokens"] as? Int) ?? 0
        let output = (usageBlock["output_tokens"] as? Int) ?? 0
        let cacheRead = (usageBlock["cache_read_input_tokens"] as? Int) ?? 0
        let cacheCreationTotal = (usageBlock["cache_creation_input_tokens"] as? Int) ?? 0

        // Prefer the explicit 5m/1h breakdown when present. If
        // missing, attribute everything to the 5m bucket — the
        // cheaper option, so we don't over-report cost.
        let cacheCreation = usageBlock["cache_creation"] as? [String: Any]
        let cache5m = (cacheCreation?["ephemeral_5m_input_tokens"] as? Int) ?? cacheCreationTotal
        let cache1h = (cacheCreation?["ephemeral_1h_input_tokens"] as? Int) ?? 0

        totals.inputTokens += input
        totals.outputTokens += output
        totals.cacheReadTokens += cacheRead
        totals.cacheWrite5mTokens += cache5m
        totals.cacheWrite1hTokens += cache1h

        usage.byModel[model] = totals
        usage.assistantMessageCount += 1
    }

    /// Compute the JSONL path for a given session record. Mirrors
    /// the encoding Claude uses (`/Users/me/proj` → `-Users-me-proj`).
    static func jsonlURL(for cwd: URL, claudeSessionId: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(cwd.claudeProjectsDirectoryName)/\(claudeSessionId).jsonl")
    }
}

private extension URL {
    /// Same encoding as in `SessionLauncherService` — every
    /// non-alphanumeric ASCII character becomes `-`.
    var claudeProjectsDirectoryName: String {
        var result = ""
        for char in standardizedFileURL.path {
            if char.isASCII && (char.isLetter || char.isNumber) {
                result.append(char)
            } else {
                result.append("-")
            }
        }
        return result
    }
}
