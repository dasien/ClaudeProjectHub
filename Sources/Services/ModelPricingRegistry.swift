import Foundation

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
        ModelPricingRegistry.copyBundledIfMissing(to: userURL)
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

    private static func copyBundledIfMissing(to userURL: URL) {
        guard !FileManager.default.fileExists(atPath: userURL.path),
              let bundleURL = Bundle.main.url(forResource: "models", withExtension: "json") else {
            return
        }
        try? FileManager.default.createDirectory(
            at: userURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.copyItem(at: bundleURL, to: userURL)
    }

    private static var empty: PricingTable {
        PricingTable(
            metadata: .init(asOf: "unknown", source: nil, currency: "USD"),
            fallback: nil,
            models: []
        )
    }

    nonisolated static var defaultUserURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeProjectHub", isDirectory: true)
            .appendingPathComponent("models.json")
    }
}
