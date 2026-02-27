import Foundation
import Observation

@Observable
final class RemoteHostManager {
    var hosts: [RemoteHost] = []
    var connections: [UUID: RemoteConnection] = [:]

    struct RemoteConnection {
        var status: ConnectionStatus = .disabled
        var sshProcess: Process?
        var localPort: UInt16 = 0
        var apiToken: String?
        var agents: [Agent] = []
        var lastError: String?
        var retryCount: Int = 0
        var webSocketTask: URLSessionWebSocketTask?
        var useWebSocket: Bool = false
    }

    /// Build a URLRequest with the remote host's API token attached.
    private func authenticatedRequest(url: URL, hostId: UUID) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = connections[hostId]?.apiToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    var allRemoteAgents: [Agent] {
        connections.values.flatMap(\.agents)
    }

    private static let storePath: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Workforce", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("remote-hosts.json")
    }()

    private let sshPath: String = {
        ["/usr/bin/ssh"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/ssh"
    }()

    // MARK: - Persistence

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(hosts) else { return }
        try? data.write(to: Self.storePath, options: .atomic)
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.storePath) else { return }
        guard let saved = try? JSONDecoder().decode([RemoteHost].self, from: data) else { return }
        hosts = saved
    }

    func addHost(_ host: RemoteHost) {
        hosts.append(host)
        save()
        if host.isEnabled {
            connect(host)
        }
    }

    func removeHost(_ id: UUID) {
        disconnect(id)
        hosts.removeAll { $0.id == id }
        connections.removeValue(forKey: id)
        save()
    }

    func updateHost(_ host: RemoteHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let wasEnabled = hosts[index].isEnabled
        hosts[index] = host
        save()

        if host.isEnabled && !wasEnabled {
            connect(host)
        } else if !host.isEnabled && wasEnabled {
            disconnect(host.id)
        } else if host.isEnabled {
            disconnect(host.id)
            connect(host)
        }
    }

    // MARK: - Connection lifecycle

    func connectAll() {
        for host in hosts where host.isEnabled {
            connect(host)
        }
    }

    func disconnectAll() {
        for host in hosts {
            disconnect(host.id)
        }
    }

    func connect(_ host: RemoteHost) {
        var conn = connections[host.id] ?? RemoteConnection()
        conn.status = .connecting
        connections[host.id] = conn

        discoverRemotePort(host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let discovery):
                self.openTunnel(host: host, remotePort: discovery.port, apiToken: discovery.token)
            case .failure(let error):
                var conn = self.connections[host.id] ?? RemoteConnection()
                conn.status = .error(error.localizedDescription)
                conn.lastError = error.localizedDescription
                self.connections[host.id] = conn
                self.scheduleRetry(host: host)
            }
        }
    }

    func disconnect(_ hostId: UUID) {
        guard var conn = connections[hostId] else { return }
        conn.webSocketTask?.cancel(with: .goingAway, reason: nil)
        conn.webSocketTask = nil
        conn.useWebSocket = false
        if let process = conn.sshProcess, process.isRunning {
            process.terminate()
        }
        conn.sshProcess = nil
        conn.status = .disabled
        conn.agents = []
        conn.retryCount = 0
        connections[hostId] = conn
    }

    func retryConnection(_ hostId: UUID) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        var conn = connections[hostId] ?? RemoteConnection()
        conn.retryCount = 0
        connections[hostId] = conn
        connect(host)
    }

    // MARK: - SSH operations

    struct RemoteDiscovery {
        let port: UInt16
        let token: String?
    }

    private func discoverRemotePort(host: RemoteHost, completion: @escaping (Result<RemoteDiscovery, Error>) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        // Read both the port and token files from the remote host
        process.arguments = host.sshBaseArgs + [
            "echo PORT=$(cat /tmp/workforce-*.port 2>/dev/null || echo NOPORT); echo TOKEN=$(cat /tmp/workforce-*.token 2>/dev/null)"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            completion(.failure(error))
            return
        }

        DispatchQueue.global().async {
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if process.terminationStatus != 0 {
                    completion(.failure(NSError(domain: "SSH", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "SSH connection failed (exit \(process.terminationStatus))"])))
                    return
                }

                // Parse PORT=<value> and TOKEN=<value> from output
                var portStr: String?
                var tokenStr: String?
                for line in output.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("PORT=") {
                        portStr = String(trimmed.dropFirst("PORT=".count))
                    } else if trimmed.hasPrefix("TOKEN=") {
                        let val = String(trimmed.dropFirst("TOKEN=".count))
                        if !val.isEmpty { tokenStr = val }
                    }
                }

                guard let portValue = portStr, portValue != "NOPORT", !portValue.isEmpty else {
                    completion(.failure(NSError(domain: "SSH", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Workforce not running on remote (no port file)"])))
                    return
                }

                guard let port = UInt16(portValue) else {
                    completion(.failure(NSError(domain: "SSH", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid port file contents: \(portValue)"])))
                    return
                }

                completion(.success(RemoteDiscovery(port: port, token: tokenStr)))
            }
        }
    }

    private func openTunnel(host: RemoteHost, remotePort: UInt16, apiToken: String?) {
        let localPort = findFreePort()
        guard localPort > 0 else {
            var conn = connections[host.id] ?? RemoteConnection()
            conn.status = .error("Could not find free local port")
            connections[host.id] = conn
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        // Build args without the destination from sshBaseArgs, then add tunnel flags and destination
        var args: [String] = []
        let baseArgs = host.sshBaseArgs
        // sshBaseArgs ends with sshDestination -- split it out
        if baseArgs.count > 1 {
            args += Array(baseArgs.dropLast())
        }
        args += ["-N", "-L", "\(localPort):localhost:\(remotePort)", host.sshDestination]
        process.arguments = args

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                guard var conn = self.connections[host.id],
                      conn.sshProcess === proc else { return }
                conn.sshProcess = nil
                conn.status = .error("SSH tunnel closed (exit \(proc.terminationStatus))")
                self.connections[host.id] = conn
                self.scheduleRetry(host: host)
            }
        }

        do {
            try process.run()
            var conn = connections[host.id] ?? RemoteConnection()
            conn.sshProcess = process
            conn.localPort = localPort
            conn.apiToken = apiToken
            conn.status = .connected
            conn.retryCount = 0
            connections[host.id] = conn

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.pollAgents(hostId: host.id)
            }
        } catch {
            var conn = connections[host.id] ?? RemoteConnection()
            conn.status = .error("Failed to start SSH: \(error.localizedDescription)")
            connections[host.id] = conn
            scheduleRetry(host: host)
        }
    }

    // MARK: - Polling

    func pollAgents(hostId: UUID) {
        guard let conn = connections[hostId], conn.status == .connected, conn.localPort > 0 else { return }

        // Skip polling when WebSocket is active and connected
        if conn.useWebSocket, let task = conn.webSocketTask, task.state == .running {
            return
        }

        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        guard let url = URL(string: "http://localhost:\(conn.localPort)/api/agents") else { return }

        var request = authenticatedRequest(url: url, hostId: hostId)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard var conn = self.connections[hostId] else { return }

                if let data, error == nil,
                   let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if var agents = try? decoder.decode([Agent].self, from: data) {
                        agents = agents.map { var a = $0; a.host = host.sshDestination; return a }
                        conn.agents = agents
                        conn.status = .connected
                    }
                    self.connections[hostId] = conn

                    // After first successful poll, try to upgrade to WebSocket
                    if !conn.useWebSocket {
                        self.connectWebSocket(hostId: hostId)
                    }
                } else {
                    self.connections[hostId] = conn
                }
            }
        }.resume()

        registerWithRemote(hostId: hostId)
    }

    // MARK: - WebSocket

    private func connectWebSocket(hostId: UUID) {
        guard let conn = connections[hostId], conn.status == .connected, conn.localPort > 0 else { return }
        guard let token = conn.apiToken else { return }
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        guard let url = URL(string: "ws://localhost:\(conn.localPort)/api/ws?token=\(token)") else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        var updated = conn
        updated.webSocketTask = task
        updated.useWebSocket = true
        connections[hostId] = updated

        receiveWebSocketMessage(hostId: hostId, host: host)
    }

    private func receiveWebSocketMessage(hostId: UUID, host: RemoteHost) {
        guard let task = connections[hostId]?.webSocketTask else { return }

        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleWebSocketText(text, hostId: hostId, host: host)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleWebSocketText(text, hostId: hostId, host: host)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveWebSocketMessage(hostId: hostId, host: host)

                case .failure:
                    // WS failed — fall back to polling
                    if var conn = self.connections[hostId] {
                        conn.webSocketTask = nil
                        conn.useWebSocket = false
                        self.connections[hostId] = conn
                    }
                }
            }
        }
    }

    private func handleWebSocketText(_ text: String, hostId: UUID, host: RemoteHost) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = json["kind"] as? String else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if kind == "snapshot" {
            guard let agentsJSON = json["agents"],
                  let agentsData = try? JSONSerialization.data(withJSONObject: agentsJSON),
                  var agents = try? decoder.decode([Agent].self, from: agentsData) else { return }
            agents = agents.map { var a = $0; a.host = host.sshDestination; return a }
            connections[hostId]?.agents = agents
        } else if kind == "event" {
            guard let eventJSON = json["event"],
                  let eventData = try? JSONSerialization.data(withJSONObject: eventJSON),
                  let event = try? decoder.decode(SocketMessage.self, from: eventData) else { return }
            applyEvent(event, hostId: hostId, host: host)
        }
    }

    private func applyEvent(_ event: SocketMessage, hostId: UUID, host: RemoteHost) {
        guard var conn = connections[hostId] else { return }

        switch event.type {
        case .register:
            var agent = Agent(
                sessionId: event.sessionId,
                name: event.name ?? NameGenerator.generate(from: event.sessionId),
                avatarSeed: event.avatarSeed ?? event.sessionId,
                cwd: event.cwd,
                agentType: event.agentType ?? "claude",
                model: event.model,
                tmuxSession: event.tmuxSession,
                host: host.sshDestination,
                status: event.status ?? .idle
            )
            conn.agents.removeAll { $0.sessionId == event.sessionId }
            conn.agents.append(agent)

        case .deregister:
            conn.agents.removeAll { $0.sessionId == event.sessionId }

        case .updateStatus, .updateTool, .notification, .subagentStart, .subagentStop, .updateTokens:
            if let idx = conn.agents.firstIndex(where: { $0.sessionId == event.sessionId }) {
                var agent = conn.agents[idx]
                agent.lastActivityAt = event.timestamp
                if let status = event.status { agent.status = status }
                if let toolName = event.toolName { agent.currentToolName = toolName }
                if event.type == .subagentStart { agent.subagentCount += 1 }
                if event.type == .subagentStop { agent.subagentCount = max(0, agent.subagentCount - 1) }
                if let input = event.inputTokens { agent.totalInputTokens = input }
                if let output = event.outputTokens { agent.totalOutputTokens = output }
                if let cacheCreation = event.cacheCreationTokens { agent.totalCacheCreationTokens = cacheCreation }
                if let cacheRead = event.cacheReadTokens { agent.totalCacheReadTokens = cacheRead }
                if let notifType = event.notificationType { agent.lastNotificationType = notifType }
                if let msg = event.notificationMessage { agent.notificationMessage = msg }
                if let path = event.transcriptPath { agent.transcriptPath = path }
                conn.agents[idx] = agent
            }
        }

        connections[hostId] = conn
    }

    // MARK: - Client registration

    func registerWithRemote(hostId: UUID) {
        guard let conn = connections[hostId], conn.status == .connected, conn.localPort > 0 else { return }
        guard let url = URL(string: "http://localhost:\(conn.localPort)/api/clients/register") else { return }

        let clientId = Self.stableClientId
        let hostname = Host.current().localizedName ?? "unknown"
        let user = NSUserName()

        let body: [String: String] = [
            "clientId": clientId,
            "hostname": hostname,
            "user": user
        ]

        guard let bodyData = try? JSONEncoder().encode(body) else { return }

        var request = authenticatedRequest(url: url, hostId: hostId)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request).resume()
    }

    private static let stableClientId: String = {
        let key = "workforceClientId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }()

    // MARK: - Retry with exponential backoff

    private func scheduleRetry(host: RemoteHost) {
        guard host.isEnabled else { return }
        guard var conn = connections[host.id] else { return }
        conn.retryCount += 1
        connections[host.id] = conn

        let delays = [5.0, 10.0, 30.0, 60.0]
        let delay = delays[min(conn.retryCount - 1, delays.count - 1)]

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let current = self.hosts.first(where: { $0.id == host.id }),
                  current.isEnabled else { return }
            self.connect(current)
        }
    }

    // MARK: - Spawn remote agent

    func spawnAgent(host: RemoteHost, cwd: String, agentType: String = "claude", completion: @escaping (Result<String, Error>) -> Void) {
        // Use the HTTP API on the remote workforce server (via SSH tunnel) so that
        // the remote server resolves tmux path from its own environment.
        guard let conn = connections[host.id], conn.status == .connected, conn.localPort > 0 else {
            completion(.failure(NSError(domain: "Workforce", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Not connected to remote host"])))
            return
        }

        guard let url = URL(string: "http://localhost:\(conn.localPort)/api/spawn") else {
            completion(.failure(NSError(domain: "Workforce", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        let body: [String: String] = ["cwd": cwd, "agentType": agentType]
        guard let bodyData = try? JSONEncoder().encode(body) else {
            completion(.failure(NSError(domain: "Workforce", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode request"])))
            return
        }

        var request = authenticatedRequest(url: url, hostId: host.id)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sessionId = json["sessionId"] as? String else {
                    let errMsg = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error"
                    completion(.failure(NSError(domain: "Workforce", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: errMsg])))
                    return
                }
                completion(.success(sessionId))
            }
        }.resume()
    }

    // MARK: - Utilities

    private func findFreePort() -> UInt16 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 0 }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 0 }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &len)
            }
        }
        guard nameResult == 0 else { return 0 }

        return UInt16(bigEndian: addr.sin_port)
    }
}
