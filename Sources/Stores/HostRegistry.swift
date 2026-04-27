import Foundation

/// Loads the hub's known hosts from
/// `~/Library/Application Support/ClaudeProjectHub/hosts.json`. Writes a
/// default file (containing just `terminal-app`) on first launch; never
/// overwrites the user's edits afterwards.
@MainActor
final class HostRegistry: ObservableObject {
    @Published private(set) var hosts: [HostConfig] = []

    private let url: URL

    init(url: URL = HostRegistry.defaultURL) {
        self.url = url
        load()
    }

    func host(forID id: String) -> HostConfig? {
        hosts.first { $0.id == id }
    }

    /// The display name to show in UI when we have a hostID. Falls back to
    /// the raw ID so a deleted/renamed host still shows something sensible.
    func displayName(forID id: String) -> String {
        host(forID: id)?.displayName ?? id
    }

    /// The bundle identifier for a hostID, when known. Used by the launcher
    /// service for process lookup and by the dialogs to check if the host
    /// is currently running.
    func bundleIdentifier(forID id: String) -> String? {
        host(forID: id)?.bundleIdentifier
    }

    private func load() {
        if !FileManager.default.fileExists(atPath: url.path) {
            writeDefaults()
        }
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([HostConfig].self, from: data) {
            hosts = decoded
        } else {
            // Fallback if the user's file is corrupt — use defaults in
            // memory but don't overwrite their file.
            hosts = HostRegistry.builtinDefaults
        }
    }

    private func writeDefaults() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(HostRegistry.builtinDefaults) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static let builtinDefaults: [HostConfig] = [
        HostConfig(
            id: "terminal-app",
            displayName: "Terminal",
            icon: "terminal.fill",
            bundleIdentifier: "com.apple.Terminal",
            strategy: .builtin(.terminalApp)
        ),
        HostConfig(
            id: "iterm2",
            displayName: "iTerm2",
            icon: "terminal.fill",
            bundleIdentifier: "com.googlecode.iterm2",
            strategy: .builtin(.iterm2)
        )
    ]

    private static var defaultURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("ClaudeProjectHub", isDirectory: true)
            .appendingPathComponent("hosts.json")
    }
}
