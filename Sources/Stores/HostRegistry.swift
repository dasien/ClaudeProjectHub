import Foundation

/// Loads and persists the hub's known hosts.
///
/// On first launch:
/// 1. Copies any default `.applescript` files from the app bundle's
///    `Resources/Scripts/` to `~/Library/Application Support/ClaudeProjectHub/scripts/`.
/// 2. If `hosts.json` doesn't exist (or fails to decode), writes a default
///    file referencing those scripts.
///
/// Edits made through the in-app Settings UI write back to `hosts.json`.
/// Edits made by the user to script files on disk are never overwritten.
@MainActor
final class HostRegistry: ObservableObject {
    @Published private(set) var hosts: [HostConfig] = []

    let scriptsDirectory: URL

    private let url: URL

    init(
        url: URL = HostRegistry.defaultURL,
        scriptsDirectory: URL = HostRegistry.defaultScriptsDirectory
    ) {
        self.url = url
        self.scriptsDirectory = scriptsDirectory
        copyBundledScriptsIfMissing()
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

    /// Resolves a host's launch script path on disk. Returns the URL even
    /// if the file doesn't exist; the launcher's `isAvailable()` checks
    /// readability.
    func scriptURL(forID id: String) -> URL? {
        guard let host = host(forID: id) else { return nil }
        return scriptsDirectory.appendingPathComponent(host.launchScript)
    }

    // MARK: - Mutations

    /// Adds a host or replaces an existing one with the same id. If the
    /// referenced script doesn't exist yet, copies the template into place
    /// so the user has something to edit.
    func add(_ host: HostConfig) {
        ensureScriptExists(for: host)
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        save()
    }

    func update(_ host: HostConfig) {
        ensureScriptExists(for: host)
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        save()
    }

    func remove(id: String) {
        hosts.removeAll { $0.id == id }
        save()
    }

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
            // Old format or corrupt — regenerate from defaults. There are
            // no production users yet, so we don't bother with migration.
            hosts = HostRegistry.builtinDefaults
            save()
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

    // MARK: - Bundled scripts

    /// Copies any `.applescript` files from the bundle's `Scripts/` folder
    /// into the user's scripts directory if they don't already exist there.
    /// User edits never get overwritten — once a file is in the user dir,
    /// it stays.
    private func copyBundledScriptsIfMissing() {
        try? FileManager.default.createDirectory(
            at: scriptsDirectory,
            withIntermediateDirectories: true
        )
        guard let bundleScriptsURL = Bundle.main.url(
            forResource: "Scripts",
            withExtension: nil
        ) else { return }
        guard let bundleContents = try? FileManager.default.contentsOfDirectory(
            at: bundleScriptsURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for bundleURL in bundleContents where bundleURL.pathExtension == "applescript" {
            let userURL = scriptsDirectory.appendingPathComponent(bundleURL.lastPathComponent)
            if !FileManager.default.fileExists(atPath: userURL.path) {
                try? FileManager.default.copyItem(at: bundleURL, to: userURL)
            }
        }
    }

    /// Ensures a host has a backing script file. If the file doesn't exist
    /// yet, copies the bundled `_template.applescript` to the host's
    /// `launchScript` filename. Used when the user adds a new host through
    /// the UI — they get an editable starter.
    private func ensureScriptExists(for host: HostConfig) {
        let target = scriptsDirectory.appendingPathComponent(host.launchScript)
        if FileManager.default.fileExists(atPath: target.path) { return }
        guard let templateURL = Bundle.main.url(
            forResource: "_template",
            withExtension: "applescript",
            subdirectory: "Scripts"
        ) ?? scriptsDirectory.appendingPathComponent("_template.applescript") as URL? else {
            return
        }
        if FileManager.default.fileExists(atPath: templateURL.path) {
            try? FileManager.default.copyItem(at: templateURL, to: target)
        }
    }

    // MARK: - Defaults

    private static let builtinDefaults: [HostConfig] = [
        HostConfig(
            id: "terminal-app",
            displayName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            launchScript: "terminal-app.applescript"
        ),
        HostConfig(
            id: "iterm2",
            displayName: "iTerm2",
            bundleIdentifier: "com.googlecode.iterm2",
            launchScript: "iterm2.applescript"
        )
    ]

    nonisolated private static var defaultURL: URL {
        appSupportRoot().appendingPathComponent("hosts.json")
    }

    nonisolated private static var defaultScriptsDirectory: URL {
        appSupportRoot().appendingPathComponent("scripts", isDirectory: true)
    }

    nonisolated private static func appSupportRoot() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("ClaudeProjectHub", isDirectory: true)
    }
}
