import Foundation

/// One entry in the host registry. Defines an application that can host
/// Claude Code sessions — Terminal, iTerm2, VSCode, Rider, Ghostty, etc.
/// Loaded from `~/Library/Application Support/ClaudeProjectHub/hosts.json`.
struct HostConfig: Codable, Identifiable, Hashable {
    /// Stable identifier — referenced by Session.hostID.
    var id: String
    var displayName: String
    /// SF Symbol name used for menu/list icons.
    var icon: String
    /// Used to find the host's process via NSWorkspace and AX. Optional
    /// because some `process`-strategy hosts (e.g. ad-hoc CLI tools) may
    /// not correspond to a single app bundle.
    var bundleIdentifier: String?
    var strategy: HostStrategy
}

extension HostConfig {
    /// Whether this host supports adding a new tab to an existing window
    /// (vs only opening fresh windows).
    var supportsNewTab: Bool {
        switch strategy {
        case .builtin(let kind):
            switch kind {
            case .terminalApp, .iterm2:
                return true
            }
        case .process:
            // CLI-spawned hosts always create a new window per invocation.
            return false
        }
    }
}

/// How a session is launched on this host.
enum HostStrategy: Codable, Hashable {
    /// One of our code-implemented launchers (Terminal, iTerm2, VSCode, …).
    /// Each `BuiltinKind` is wired to a concrete `SessionLauncher` in the
    /// service's dispatcher.
    case builtin(BuiltinKind)
    /// Generic CLI-spawnable host. The executable is invoked with the given
    /// arguments. ProcessLauncher substitutes `{cwd}`, `{claude}`, and
    /// `{command}` tokens at launch time.
    case process(executable: String, arguments: [String])
}

enum BuiltinKind: String, Codable, Hashable, CaseIterable {
    case terminalApp = "terminal-app"
    case iterm2
    // Future: vscode, xcode, androidStudio
}

extension BuiltinKind {
    /// Sensible default fields when the user picks this kind in the editor.
    var suggestedDisplayName: String {
        switch self {
        case .terminalApp: return "Terminal"
        case .iterm2: return "iTerm2"
        }
    }

    var suggestedBundleIdentifier: String {
        switch self {
        case .terminalApp: return "com.apple.Terminal"
        case .iterm2: return "com.googlecode.iterm2"
        }
    }

    var suggestedIcon: String {
        switch self {
        case .terminalApp, .iterm2: return "terminal.fill"
        }
    }
}

// MARK: - Codable for the tagged HostStrategy enum

extension HostStrategy {
    private enum CodingKeys: String, CodingKey {
        case type
        case kind
        case executable
        case arguments
    }

    private enum StrategyType: String, Codable {
        case builtin
        case process
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StrategyType.self, forKey: .type)
        switch type {
        case .builtin:
            let kind = try container.decode(BuiltinKind.self, forKey: .kind)
            self = .builtin(kind)
        case .process:
            let executable = try container.decode(String.self, forKey: .executable)
            let arguments = try container.decode([String].self, forKey: .arguments)
            self = .process(executable: executable, arguments: arguments)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let kind):
            try container.encode(StrategyType.builtin, forKey: .type)
            try container.encode(kind, forKey: .kind)
        case .process(let executable, let arguments):
            try container.encode(StrategyType.process, forKey: .type)
            try container.encode(executable, forKey: .executable)
            try container.encode(arguments, forKey: .arguments)
        }
    }
}
