import Foundation

enum TranscriptReader {
    /// Reads the last `count` assistant text messages from a JSONL transcript file.
    static func lastAssistantMessages(from path: String, count: Int = 10) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var messages: [String] = []
        for line in content.split(separator: "\n").reversed() where !line.isEmpty {
            guard let lineData = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "assistant",
                  let contentBlocks = message["content"] as? [[String: Any]] else {
                continue
            }

            let texts = contentBlocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }

            if !texts.isEmpty {
                messages.append(texts.joined(separator: "\n"))
            }

            if messages.count >= count { break }
        }

        return messages.reversed()
    }
}
