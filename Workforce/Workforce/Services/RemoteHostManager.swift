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
        var agents: [Agent] = []
        var lastError: String?
        var retryCount: Int = 0
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
            case .success(let remotePort):
                self.openTunnel(host: host, remotePort: remotePort)
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

    private func discoverRemotePort(host: RemoteHost, completion: @escaping (Result<UInt16, Error>) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = host.sshBaseArgs + ["cat /tmp/workforce-*.port 2>/dev/null || echo NOPORT"]

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
                } else if output == "NOPORT" || output.isEmpty {
                    completion(.failure(NSError(domain: "SSH", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Workforce not running on remote (no port file)"])))
                } else if let port = UInt16(output) {
                    completion(.success(port))
                } else {
                    completion(.failure(NSError(domain: "SSH", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid port file contents: \(output)"])))
                }
            }
        }
    }

    private func openTunnel(host: RemoteHost, remotePort: UInt16) {
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
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        guard let url = URL(string: "http://localhost:\(conn.localPort)/api/agents") else { return }

        var request = URLRequest(url: url)
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
                        agents = agents.map { agent in
                            Agent(
                                sessionId: agent.sessionId,
                                name: agent.name,
                                avatarSeed: agent.avatarSeed,
                                cwd: agent.cwd,
                                agentType: agent.agentType,
                                model: agent.model,
                                tmuxSession: agent.tmuxSession,
                                host: host.sshDestination,
                                startedAt: agent.startedAt,
                                lastActivityAt: agent.lastActivityAt,
                                status: agent.status,
                                currentToolName: agent.currentToolName,
                                lastNotificationType: agent.lastNotificationType,
                                subagentCount: agent.subagentCount,
                                paneTitle: agent.paneTitle,
                                transcriptPath: agent.transcriptPath,
                                notificationMessage: agent.notificationMessage,
                                totalInputTokens: agent.totalInputTokens,
                                totalOutputTokens: agent.totalOutputTokens,
                                totalCacheCreationTokens: agent.totalCacheCreationTokens,
                                totalCacheReadTokens: agent.totalCacheReadTokens
                            )
                        }
                        conn.agents = agents
                        conn.status = .connected
                    }
                }
                self.connections[hostId] = conn
            }
        }.resume()

        registerWithRemote(hostId: hostId)
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

        var request = URLRequest(url: url)
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
        let timestamp = Int(Date().timeIntervalSince1970)
        let sessionName = "workforce-\(timestamp)"

        let remoteCommand = "export PATH=\"$HOME/.local/bin:$HOME/bin:/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" && tmux new-session -d -s \(sessionName) -c '\(cwd)' -e WORKFORCE_SESSION=\(sessionName) -- zsh -lc '\(agentType)'"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = host.sshBaseArgs + [remoteCommand]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            completion(.failure(error))
            return
        }

        DispatchQueue.global().async {
            process.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    completion(.success(sessionName))
                } else {
                    completion(.failure(NSError(domain: "SSH", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: errMsg.isEmpty ? "Remote command failed" : errMsg])))
                }
            }
        }
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
