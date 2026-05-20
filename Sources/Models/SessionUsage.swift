import Foundation

/// Token totals aggregated across an entire JSONL transcript, broken
/// out per model so a session that mixed Sonnet with Opus prices each
/// segment correctly.
struct SessionUsage: Equatable, Codable {
    /// Per-model token totals.
    var byModel: [String: ModelTotals] = [:]
    /// Number of assistant messages we counted (not tool calls or
    /// snapshot lines).
    var assistantMessageCount: Int = 0

    struct ModelTotals: Equatable, Codable {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheWrite5mTokens: Int = 0
        var cacheWrite1hTokens: Int = 0
        var cacheReadTokens: Int = 0

        var totalTokens: Int {
            inputTokens + outputTokens + cacheWrite5mTokens + cacheWrite1hTokens + cacheReadTokens
        }
    }

    /// Convenience: sum of all tokens across all models.
    var totalTokens: Int {
        byModel.values.reduce(0) { $0 + $1.totalTokens }
    }

    /// Compute the total cost in dollars using the provided pricing
    /// registry. Models with no matching pricing entry contribute 0
    /// to the total — caller can detect by comparing model ids in
    /// `byModel.keys` against `registry.pricing(forModel:)`.
    @MainActor
    func totalCost(using registry: ModelPricingRegistry) -> Double {
        byModel.reduce(0.0) { running, pair in
            let (modelID, totals) = pair
            guard let entry = registry.pricing(forModel: modelID) else { return running }
            return running + entry.pricing.cost(
                inputTokens: totals.inputTokens,
                outputTokens: totals.outputTokens,
                cacheWrite5mTokens: totals.cacheWrite5mTokens,
                cacheWrite1hTokens: totals.cacheWrite1hTokens,
                cacheReadTokens: totals.cacheReadTokens
            )
        }
    }
}
