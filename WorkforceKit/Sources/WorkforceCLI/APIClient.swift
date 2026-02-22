import Foundation
import WorkforceKit

enum APIClient {
    private static let portFilePath = "/tmp/workforce-\(getuid()).port"

    static func fetchAgents() -> [Agent]? {
        guard let port = readPort() else { return nil }
        guard let url = URL(string: "http://localhost:\(port)/api/agents") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        let semaphore = DispatchSemaphore(value: 0)
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

    private static func readPort() -> UInt16? {
        guard let content = try? String(contentsOfFile: portFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let port = UInt16(content) else { return nil }
        return port
    }
}
