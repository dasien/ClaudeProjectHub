import Foundation

/// Per-1M-token pricing for a Claude model. All amounts are in the
/// currency declared by the enclosing `PricingTable.metadata`.
struct ModelPricing: Codable, Equatable {
    let input: Double
    let output: Double
    /// 5-minute prompt cache write rate (Anthropic's default cache TTL).
    let cacheWrite5m: Double
    /// 1-hour prompt cache write rate (long-lived cache option).
    let cacheWrite1h: Double
    /// Cache hit rate — paid when a cached prefix is reused.
    let cacheRead: Double

    /// Compute total cost in dollars given token counts.
    func cost(
        inputTokens: Int,
        outputTokens: Int,
        cacheWrite5mTokens: Int,
        cacheWrite1hTokens: Int,
        cacheReadTokens: Int
    ) -> Double {
        let perMillion = 1_000_000.0
        let i = Double(inputTokens) * input / perMillion
        let o = Double(outputTokens) * output / perMillion
        let w5 = Double(cacheWrite5mTokens) * cacheWrite5m / perMillion
        let w1h = Double(cacheWrite1hTokens) * cacheWrite1h / perMillion
        let r = Double(cacheReadTokens) * cacheRead / perMillion
        return i + o + w5 + w1h + r
    }
}

/// One model entry in `models.json`. The `patterns` are matched
/// against the model id seen in JSONL transcripts (`message.model`)
/// using glob-style `LIKE` matching (`*` wildcard). First entry whose
/// pattern matches wins, so list specific patterns before generic
/// ones.
struct ModelPricingEntry: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let patterns: [String]
    let pricing: ModelPricing

    func matches(modelID: String) -> Bool {
        patterns.contains { pattern in
            NSPredicate(format: "SELF LIKE %@", pattern).evaluate(with: modelID)
        }
    }
}

/// Top-level shape of `models.json`.
struct PricingTable: Codable, Equatable {
    struct Metadata: Codable, Equatable {
        let asOf: String
        let source: String?
        let currency: String?
    }

    let metadata: Metadata
    /// Optional fallback model id used when no pattern matches. Set
    /// to nil if you'd rather show "unknown model" + zero cost than
    /// risk pricing a new model with stale numbers.
    let fallback: String?
    let models: [ModelPricingEntry]
    /// Bumped whenever the bundled table gains models or corrected
    /// rates, so an existing install can tell it's behind. Absent in
    /// tables written before versioning — treated as 0.
    let version: Int?

    var tableVersion: Int { version ?? 0 }
}
