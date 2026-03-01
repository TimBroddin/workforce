import Foundation

public struct TokenUsageSummary: Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
}

public enum TranscriptParser {
    public static func parseTokenUsage(from path: String) -> TokenUsageSummary {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return TokenUsageSummary(inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
        }

        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0

        for line in content.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            totalInput += usage["input_tokens"] as? Int ?? 0
            totalOutput += usage["output_tokens"] as? Int ?? 0
            totalCacheCreation += usage["cache_creation_input_tokens"] as? Int ?? 0
            totalCacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
        }

        return TokenUsageSummary(
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: totalCacheCreation,
            cacheReadTokens: totalCacheRead
        )
    }
}
