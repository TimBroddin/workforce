import Foundation
import WorkforceKit

enum APIClient {
    private static let portFilePath = "/tmp/workforce-\(getuid()).port"
    private static let tokenFilePath = "/tmp/workforce-\(getuid()).token"

    private static func readToken() -> String? {
        try? String(contentsOfFile: tokenFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func addAuth(to request: inout URLRequest) {
        if let token = readToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    static func fetchAgents() -> [Agent]? {
        guard let port = readPort() else { return nil }
        guard let url = URL(string: "http://localhost:\(port)/api/agents") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        addAuth(to: &request)

        let semaphore = DispatchSemaphore(value: 0)
        // Safety: semaphore.wait() provides a happens-before guarantee between
        // the callback writing `result` and the read after wait() returns.
        nonisolated(unsafe) var result: [Agent]?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data, error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            result = try? decoder.decode([Agent].self, from: data)
        }
        task.resume()
        semaphore.wait()
        return result
    }

    static func post(_ message: SocketMessage) {
        guard let port = readPort() else { return }
        guard let url = URL(string: "http://localhost:\(port)/api/events") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 2
        addAuth(to: &request)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(message) else { return }
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
    }

    /// Ask the Workforce app to spawn a new agent. Returns the session name on success.
    static func spawn(cwd: String, agentType: String) -> String? {
        guard let port = readPort() else { return nil }
        guard let url = URL(string: "http://localhost:\(port)/api/spawn") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        addAuth(to: &request)

        let body: [String: String] = ["cwd": cwd, "agentType": agentType]
        guard let bodyData = try? JSONEncoder().encode(body) else { return nil }
        request.httpBody = bodyData

        let semaphore = DispatchSemaphore(value: 0)
        // Safety: semaphore.wait() provides a happens-before guarantee between
        // the callback writing `result` and the read after wait() returns.
        nonisolated(unsafe) var result: String?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data, error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["sessionId"] as? String else { return }
            result = sessionId
        }
        task.resume()
        semaphore.wait()
        return result
    }

    private static func readPort() -> UInt16? {
        guard let content = try? String(contentsOfFile: portFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let port = UInt16(content) else { return nil }
        return port
    }
}
