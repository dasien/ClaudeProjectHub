import Foundation

/// Loads the hub's known hosts from
/// `~/Library/Application Support/ClaudeProjectHub/hosts.json` and persists
/// changes back to the same file. On first launch (file doesn't exist) the
/// registry writes a default file containing the built-in hosts. After
/// that, every add/update/remove writes the current state — so a future
/// app launch reads back exactly what the user last saw.
@MainActor
final class HostRegistry: ObservableObject {
    @Published private(set) var hosts: [HostConfig] = []

    private let url: URL

    init(url: URL = HostRegistry.defaultURL) {
        self.url = url
        load()
    }

    // MARK: - Reads

    func host(forID id: String) -> HostConfig? {
        hosts.first { $0.id == id }
    }

    func displayName(forID id: String) -> String {
        host(forID: id)?.displayName ?? id
    }

    func bundleIdentifier(forID id: String) -> String? {
        host(forID: id)?.bundleIdentifier
    }

    // MARK: - Mutations

    /// Adds a host or replaces an existing one with the same id. Persists
    /// to disk.
    func add(_ host: HostConfig) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        save()
    }

    /// Updates an existing host (no-op if id isn't found). Persists to disk.
    func update(_ host: HostConfig) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        save()
    }

    /// Removes the host with the given id. Persists to disk.
    func remove(id: String) {
        hosts.removeAll { $0.id == id }
        save()
    }

    /// Whether `proposedID` is unused (or is the id of `excluding`, e.g.
    /// when editing an existing host with its current id). Useful for the
    /// editor to validate uniqueness.
    func isIDAvailable(_ proposedID: String, excluding: String? = nil) -> Bool {
        !hosts.contains { $0.id == proposedID && $0.id != excluding }
    }

    // MARK: - Persistence

    private func load() {
        if !FileManager.default.fileExists(atPath: url.path) {
            hosts = HostRegistry.builtinDefaults
            save()
            return
        }
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([HostConfig].self, from: data) {
            hosts = decoded
        } else {
            // File exists but corrupt — use defaults in memory but don't
            // overwrite the user's file.
            hosts = HostRegistry.builtinDefaults
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hosts) else { return }
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

    nonisolated private static var defaultURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("ClaudeProjectHub", isDirectory: true)
            .appendingPathComponent("hosts.json")
    }
}
