import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum SummarizationBackend: String, CaseIterable, Identifiable {
    case appleIntelligence = "Apple Intelligence"
    case openRouter = "OpenRouter"
    var id: String { rawValue }

    /// Backends available on the current system.
    static var availableCases: [SummarizationBackend] {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return allCases
        }
        #endif
        return [.openRouter]
    }

    /// Whether Apple Intelligence is ready to use on this system.
    static var isAppleIntelligenceReady: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Sensible default for the current system.
    static var systemDefault: SummarizationBackend {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return .appleIntelligence
        }
        #endif
        return .openRouter
    }
}

actor TranscriptSummarizer {
    static let shared = TranscriptSummarizer()

    private let systemPrompt = """
    Summarize what this AI coding agent has been working on in 1-2 short sentences \
    for a macOS notification. Be specific about files and actions. \
    Do not start with "The agent" — just describe the work.
    """

    func summarize(transcriptPath: String, messages: [String], backend: SummarizationBackend) async -> String? {
        guard !messages.isEmpty else { return nil }

        // Truncate to ~4000 chars to keep it fast
        let combined = messages.joined(separator: "\n---\n")
        let truncated = String(combined.prefix(4000))

        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    switch backend {
                    case .appleIntelligence:
                        return try await self.summarizeWithAppleIntelligence(truncated)
                    case .openRouter:
                        return try await self.summarizeWithOpenRouter(truncated)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    return nil // timeout sentinel
                }
                // First result wins
                for try await result in group {
                    group.cancelAll()
                    return result
                }
                return nil
            }
        } catch {
            return nil
        }
    }

    private func summarizeWithAppleIntelligence(_ text: String) async throws -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return nil }
        let model = SystemLanguageModel.default
        guard model.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(to: text)
        let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
        #else
        return nil
        #endif
    }

    private func summarizeWithOpenRouter(_ text: String) async throws -> String? {
        guard let apiKey = UserDefaults.standard.string(forKey: "openRouterAPIKey"),
              !apiKey.isEmpty else { return nil }
        let model = UserDefaults.standard.string(forKey: "openRouterModel") ?? "google/gemini-2.5-flash-lite"

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "max_tokens": 100,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
