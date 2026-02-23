import Foundation
import Network

final class HTTPServer {
    private var listener: NWListener?
    private let store: AgentStore
    private let eventLog: EventLog
    private let portFilePath: String
    private let encoder: JSONEncoder

    init(store: AgentStore, eventLog: EventLog) {
        self.store = store
        self.eventLog = eventLog
        self.portFilePath = "/tmp/workforce-\(getuid()).port"

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    func start(listenOnAllInterfaces: Bool = false) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: listenOnAllInterfaces ? "0.0.0.0" : .ipv4(.loopback),
            port: .any
        )

        listener = try NWListener(using: params)

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener?.port {
                    self.writePortFile(port: port.rawValue)
                    NSLog("[Workforce] HTTP server listening on port %d", port.rawValue)
                }
            case .failed(let error):
                NSLog("[Workforce] HTTP server failed: %@", error.localizedDescription)
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: portFilePath)
    }

    // MARK: - Port file

    private func writePortFile(port: UInt16) {
        let data = Data("\(port)".utf8)
        FileManager.default.createFile(atPath: portFilePath, contents: data)
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let content { buffer.append(content) }

            // Check if we have the full HTTP headers (terminated by \r\n\r\n)
            if let headerEnd = self.findHeaderEnd(in: buffer) {
                let headerData = Data(buffer[buffer.startIndex..<headerEnd])
                let bodySoFar = Data(buffer[headerEnd...])
                let expectedLength = self.parseContentLength(from: headerData)

                if expectedLength > 0, bodySoFar.count < expectedLength {
                    self.receiveBody(on: connection, headerData: headerData, accumulated: bodySoFar, expected: expectedLength)
                } else {
                    self.processRequest(headerData, body: bodySoFar, on: connection)
                }
            } else if isComplete || error != nil {
                // Connection closed before full headers received
                if !buffer.isEmpty {
                    self.processRequest(buffer, body: Data(), on: connection)
                } else {
                    connection.cancel()
                }
            } else {
                self.receiveRequest(on: connection, accumulated: buffer)
            }
        }
    }

    private func receiveBody(on connection: NWConnection, headerData: Data, accumulated: Data, expected: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let content { buffer.append(content) }

            if buffer.count >= expected || isComplete || error != nil {
                self.processRequest(headerData, body: buffer, on: connection)
            } else {
                self.receiveBody(on: connection, headerData: headerData, accumulated: buffer, expected: expected)
            }
        }
    }

    private func parseContentLength(from headerData: Data) -> Int {
        guard let headerString = String(data: headerData, encoding: .utf8) else { return 0 }
        let lines = headerString.split(separator: "\r\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private func findHeaderEnd(in data: Data) -> Data.Index? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        guard data.count >= 4 else { return nil }
        for i in data.startIndex...(data.endIndex - 4) {
            if data[i] == separator[0]
                && data[i + 1] == separator[1]
                && data[i + 2] == separator[2]
                && data[i + 3] == separator[3] {
                return i + 4
            }
        }
        return nil
    }

    // MARK: - Request parsing & routing

    private func processRequest(_ headerData: Data, body: Data, on connection: NWConnection) {
        guard let requestLine = parseRequestLine(from: headerData) else {
            sendResponse(on: connection, status: "400 Bad Request", body: #"{"error":"bad request"}"#)
            return
        }

        let method = requestLine.method
        let path = requestLine.path

        switch (method, path) {
        case ("GET", "/api/agents"):
            handleGetAgents(on: connection)
        case ("GET", let p) where p.hasPrefix("/api/agents/"):
            let id = String(p.dropFirst("/api/agents/".count))
            if id.isEmpty {
                handleGetAgents(on: connection)
            } else {
                handleGetAgent(id: id, on: connection)
            }
        case ("POST", "/api/events"):
            handlePostEvent(body: body, on: connection)
        case ("OPTIONS", _):
            sendResponse(on: connection, status: "204 No Content", body: "")
        default:
            sendResponse(on: connection, status: "404 Not Found", body: #"{"error":"not found"}"#)
        }
    }

    private struct RequestLine {
        let method: String
        let path: String
    }

    private func parseRequestLine(from data: Data) -> RequestLine? {
        guard let headerString = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = headerString.split(separator: "\r\n", maxSplits: 1).first
            ?? headerString.split(separator: "\n", maxSplits: 1).first
        guard let line = firstLine else { return nil }

        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        var path = String(parts[1])

        // Strip query string
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[path.startIndex..<queryIndex])
        }

        return RequestLine(method: method, path: path)
    }

    // MARK: - Handlers

    private func handleGetAgents(on connection: NWConnection) {
        do {
            let agents = store.sortedAgents
            let data = try encoder.encode(agents)
            let body = String(data: data, encoding: .utf8) ?? "[]"
            sendResponse(on: connection, status: "200 OK", body: body)
        } catch {
            sendResponse(on: connection, status: "500 Internal Server Error", body: #"{"error":"encoding failed"}"#)
        }
    }

    private func handleGetAgent(id: String, on connection: NWConnection) {
        guard let agent = store.agents[id] else {
            sendResponse(on: connection, status: "404 Not Found", body: #"{"error":"agent not found"}"#)
            return
        }
        do {
            let data = try encoder.encode(agent)
            let body = String(data: data, encoding: .utf8) ?? "{}"
            sendResponse(on: connection, status: "200 OK", body: body)
        } catch {
            sendResponse(on: connection, status: "500 Internal Server Error", body: #"{"error":"encoding failed"}"#)
        }
    }

    private func handlePostEvent(body: Data, on connection: NWConnection) {
        let raw = String(data: body, encoding: .utf8) ?? "<invalid utf8>"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let message = try decoder.decode(SocketMessage.self, from: body)
            NSLog("[Workforce] HTTP event: type=%@ session=%@", message.type.rawValue, message.sessionId)
            eventLog.append(message: message, rawJSON: raw)
            store.handleMessage(message)
            sendResponse(on: connection, status: "200 OK", body: #"{"ok":true}"#)
        } catch {
            NSLog("[Workforce] HTTP event decode error: %@", error.localizedDescription)
            eventLog.append(message: nil, rawJSON: raw, error: error.localizedDescription)
            sendResponse(on: connection, status: "400 Bad Request", body: #"{"error":"invalid message"}"#)
        }
    }

    // MARK: - Response

    private func sendResponse(on connection: NWConnection, status: String, body: String) {
        let response = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "",
            body,
        ].joined(separator: "\r\n")

        let data = Data(response.utf8)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
