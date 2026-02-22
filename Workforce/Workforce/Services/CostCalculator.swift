import Foundation

enum CostCalculator {
    struct ModelPricing {
        let inputPerMillion: Double
        let outputPerMillion: Double
    }

    // Pricing as of 2026-02 (USD per million tokens)
    private static let pricing: [String: ModelPricing] = [
        "claude-opus-4-6": ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0),
        "claude-sonnet-4-6": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0),
        "claude-haiku-4-5": ModelPricing(inputPerMillion: 0.80, outputPerMillion: 4.0),
    ]

    private static let defaultPricing = ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0)

    static func estimateCost(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) -> Double {
        let p = pricing[model ?? ""] ?? defaultPricing
        let inputCost = Double(inputTokens) / 1_000_000.0 * p.inputPerMillion
        let outputCost = Double(outputTokens) / 1_000_000.0 * p.outputPerMillion
        let cacheCreateCost = Double(cacheCreationTokens) / 1_000_000.0 * p.inputPerMillion * 1.25
        let cacheReadCost = Double(cacheReadTokens) / 1_000_000.0 * p.inputPerMillion * 0.1
        return inputCost + outputCost + cacheCreateCost + cacheReadCost
    }

    static func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return "<$0.01"
        }
        return String(format: "$%.2f", cost)
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }
}
