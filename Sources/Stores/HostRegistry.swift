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
        applyDefaultsIfNeeded()
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

    /// Bring `hosts.json` up to the current `builtinDefaults` when
    /// the user's saved version is older. Backs up the existing file
    /// to `hosts.json.backup` first so the user can recover any
    /// custom hosts they had before the update wiped the file. Then
    /// removes `hosts.json` so `load()` will rewrite it from the new
    /// defaults.
    private func applyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let lastSeen = defaults.integer(forKey: HostRegistry.lastSeenDefaultsVersionKey)
        guard lastSeen < HostRegistry.currentDefaultsVersion else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            let backupURL = url.appendingPathExtension("backup")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: url, to: backupURL)
            try? FileManager.default.removeItem(at: url)
        }

        defaults.set(HostRegistry.currentDefaultsVersion, forKey: HostRegistry.lastSeenDefaultsVersionKey)
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

    /// Bumped whenever `builtinDefaults` changes. On startup, if the
    /// user's saved default-version (in UserDefaults) is older than
    /// this, `applyDefaultsIfNeeded` backs up their existing
    /// `hosts.json` to `hosts.json.backup` and rewrites the file from
    /// `builtinDefaults`. The user can recover any custom hosts they
    /// had by reading the backup.
    private static let currentDefaultsVersion = 2
    private static let lastSeenDefaultsVersionKey = "HostRegistryDefaultsVersion"

    /// Hosts shipped pre-configured. The user can add/remove/edit
    /// hosts in Settings, but launching with no `hosts.json` (or a
    /// post-update reset) repopulates from this list. PyCharm
    /// bundle id was confirmed against an actual install; the rest
    /// follow JetBrains' published patterns. Bundle id casing
    /// doesn't affect runtime lookup (LaunchServices is
    /// case-insensitive) but we follow JetBrains' convention where
    /// known.
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
        ),
        HostConfig(
            id: "visual-studio-code",
            displayName: "Visual Studio Code",
            bundleIdentifier: "com.microsoft.VSCode",
            launchScript: "visual-studio-code.applescript"
        ),
        HostConfig(
            id: "intellij-idea",
            displayName: "IntelliJ IDEA",
            bundleIdentifier: "com.jetbrains.intellij",
            launchScript: "intellij-idea.applescript"
        ),
        HostConfig(
            id: "pycharm",
            displayName: "PyCharm",
            bundleIdentifier: "com.jetbrains.pycharm",
            launchScript: "pycharm.applescript"
        ),
        HostConfig(
            id: "webstorm",
            displayName: "WebStorm",
            bundleIdentifier: "com.jetbrains.WebStorm",
            launchScript: "webstorm.applescript"
        ),
        HostConfig(
            id: "phpstorm",
            displayName: "PhpStorm",
            bundleIdentifier: "com.jetbrains.PhpStorm",
            launchScript: "phpstorm.applescript"
        ),
        HostConfig(
            id: "rubymine",
            displayName: "RubyMine",
            bundleIdentifier: "com.jetbrains.rubymine",
            launchScript: "rubymine.applescript"
        ),
        HostConfig(
            id: "clion",
            displayName: "CLion",
            bundleIdentifier: "com.jetbrains.CLion",
            launchScript: "clion.applescript"
        ),
        HostConfig(
            id: "goland",
            displayName: "GoLand",
            bundleIdentifier: "com.jetbrains.goland",
            launchScript: "goland.applescript"
        ),
        HostConfig(
            id: "rider",
            displayName: "Rider",
            bundleIdentifier: "com.jetbrains.rider",
            launchScript: "rider.applescript"
        ),
        HostConfig(
            id: "android-studio",
            displayName: "Android Studio",
            bundleIdentifier: "com.google.android.studio",
            launchScript: "android-studio.applescript"
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
