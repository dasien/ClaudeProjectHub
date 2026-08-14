import Foundation
import OSLog

private let pricingLog = Logger(subsystem: "com.bgentry.ClaudeProjectHub", category: "Pricing")

/// Loads `models.json` once and looks up pricing by model id. Mirrors
/// the script-loading pattern used by `HostRegistry`: defaults ship in
/// the bundle and copy to `~/Library/Application Support/.../models.json`
/// on first run; the user can edit the user-dir copy directly to
/// adjust pricing without rebuilding the app.
@MainActor
final class ModelPricingRegistry: ObservableObject {
    @Published private(set) var table: PricingTable

    private let userURL: URL

    init(userURL: URL = ModelPricingRegistry.defaultUserURL) {
        self.userURL = userURL
        ModelPricingRegistry.installOrUpdateBundled(to: userURL)
        self.table = ModelPricingRegistry.load(from: userURL) ?? ModelPricingRegistry.empty
    }

    /// Lookup the pricing for a model id (e.g. "claude-opus-4-6").
    /// Returns nil if no pattern matches and no fallback is set.
    func pricing(forModel modelID: String) -> ModelPricingEntry? {
        if let entry = table.models.first(where: { $0.matches(modelID: modelID) }) {
            return entry
        }
        if let fallbackID = table.fallback,
           let entry = table.models.first(where: { $0.id == fallbackID }) {
            return entry
        }
        return nil
    }

    // MARK: - Disk I/O

    private static func load(from url: URL) -> PricingTable? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PricingTable.self, from: data)
    }

    /// Installs the bundled table, and updates an existing user copy when
    /// the bundle is newer.
    ///
    /// This used to be copy-only-if-missing, which meant a corrected table
    /// never reached anyone who had already run the app once — every
    /// install kept whatever shipped the first time, so new models silently
    /// priced at $0 forever. The file is deliberately user-editable, so an
    /// out-of-date copy can't just be clobbered: the previous file is kept
    /// alongside as `models.<version>.backup.json` whenever we replace it.
    private static func installOrUpdateBundled(to userURL: URL) {
        guard let bundleURL = Bundle.main.url(forResource: "models", withExtension: "json") else {
            pricingLog.error("no bundled models.json found")
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: userURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard fm.fileExists(atPath: userURL.path) else {
            try? fm.copyItem(at: bundleURL, to: userURL)
            return
        }
        guard let bundled = load(from: bundleURL) else {
            pricingLog.error("bundled models.json failed to decode — leaving the user copy alone")
            return
        }
        let userVersion = load(from: userURL)?.tableVersion ?? 0
        guard bundled.tableVersion > userVersion else {
            pricingLog.notice("models.json up to date (user v\(userVersion, privacy: .public), bundled v\(bundled.tableVersion, privacy: .public))")
            return
        }

        let backup = userURL
            .deletingLastPathComponent()
            .appendingPathComponent("models.\(userVersion).backup.json")
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: userURL, to: backup)
        try? fm.removeItem(at: userURL)
        try? fm.copyItem(at: bundleURL, to: userURL)
        pricingLog.notice("Updated models.json from v\(userVersion, privacy: .public) to v\(bundled.tableVersion, privacy: .public); previous kept at \(backup.lastPathComponent, privacy: .public)")
    }

    private static var empty: PricingTable {
        PricingTable(
            metadata: .init(asOf: "unknown", source: nil, currency: "USD"),
            fallback: nil,
            models: [],
            version: 0
        )
    }

    nonisolated static var defaultUserURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeProjectHub", isDirectory: true)
            .appendingPathComponent("models.json")
    }
}
