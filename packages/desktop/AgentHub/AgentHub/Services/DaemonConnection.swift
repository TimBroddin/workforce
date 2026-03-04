import Foundation
import Observation

@Observable
final class DaemonConnection {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    var state: ConnectionState = .disconnected

    /// Exposed for terminal WebSocket connections.
    private(set) var daemonPort: Int?
    /// Exposed for terminal WebSocket connections.
    private(set) var daemonToken: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTimer: Timer?
    private weak var agentStore: AgentStore?
    private weak var eventLog: EventLog?

    // Path to daemon config
    private let daemonPortPath: String
    private let daemonTokenPath: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.daemonPortPath = "\(home)/.agenthub/daemon.port"
        self.daemonTokenPath = "\(home)/.agenthub/daemon.token"
    }

    func setStore(_ store: AgentStore) {
        self.agentStore = store
    }

    func setEventLog(_ log: EventLog) {
        self.eventLog = log
    }

    // MARK: - Daemon Config

    struct DaemonConfig {
        let port: Int
        let token: String
    }

    /// Read daemon port and token from filesystem.
    func readDaemonConfig() throws -> DaemonConfig {
        let portString = try String(contentsOfFile: daemonPortPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portString) else {
            throw NSError(domain: "AgentHub", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid daemon port"])
        }
        let token = try String(contentsOfFile: daemonTokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DaemonConfig(port: port, token: token)
    }

    // MARK: - Connection lifecycle

    func connect() {
        state = .connecting

        do {
            let config = try readDaemonConfig()
            self.daemonPort = config.port
            self.daemonToken = config.token
            connectWebSocket()
        } catch {
            state = .error("Cannot read daemon config: \(error.localizedDescription)")
            scheduleReconnect()
        }
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        state = .disconnected
    }

    // MARK: - WebSocket

    private func connectWebSocket() {
        guard let port = daemonPort, let token = daemonToken else { return }

        guard let url = URL(string: "ws://127.0.0.1:\(port)/ws/control?token=\(token)") else {
            state = .error("Invalid WebSocket URL")
            return
        }

        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        webSocketTask = task

        state = .connected
        receiveMessage()

        // Fetch initial agent list via HTTP
        refreshAgents()
    }

    private func receiveMessage() {
        guard let task = webSocketTask else { return }

        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleIncomingMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleIncomingMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    // Continue receiving
                    self.receiveMessage()

                case .failure(let error):
                    print("[AgentHub] WebSocket error: \(error.localizedDescription)")
                    self.webSocketTask = nil
                    self.state = .error("WebSocket disconnected")
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleIncomingMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let kind = json["kind"] as? String ?? json["type"] as? String ?? ""

                switch kind {
                case "snapshot", "agents":
                    // Full agent list — decode and sync via register/deregister messages
                    if let agentsJSON = json["agents"] {
                        guard let agentsData = try? JSONSerialization.data(withJSONObject: agentsJSON) else { return }
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        if let agents = try? decoder.decode([Agent].self, from: agentsData) {
                            syncAgents(agents)
                        }
                    }

                case "event":
                    // Wrapped event — unwrap and decode as SocketMessage
                    if let eventJSON = json["event"] {
                        guard let eventData = try? JSONSerialization.data(withJSONObject: eventJSON) else { return }
                        let rawJSON = String(data: eventData, encoding: .utf8) ?? ""
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let message = try? decoder.decode(SocketMessage.self, from: eventData)
                        if let message {
                            agentStore?.handleMessage(message)
                        }
                        eventLog?.append(message: message, rawJSON: rawJSON)
                    }

                default:
                    // Try decoding as a bare SocketMessage
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let message = try? decoder.decode(SocketMessage.self, from: data) {
                        agentStore?.handleMessage(message)
                    }
                }
            }
        } catch {
            print("[AgentHub] Failed to parse message: \(error)")
        }
    }

    /// Replace all agents in the store with the ones from the daemon snapshot.
    /// Only mutates the store when something actually changed to avoid unnecessary SwiftUI re-renders.
    private func syncAgents(_ incoming: [Agent]) {
        guard let store = agentStore else { return }

        let incomingIds = Set(incoming.map(\.sessionId))

        // Remove agents that are no longer reported by the daemon
        for id in store.agents.keys where !incomingIds.contains(id) {
            let cwd = store.agents[id]?.cwd ?? ""
            store.handleMessage(SocketMessage(type: .deregister, sessionId: id, cwd: cwd))
        }

        // Register or update agents from the snapshot, but only if something visible changed
        for agent in incoming {
            if let existing = store.agents[agent.sessionId] {
                // Only update if something the UI cares about has changed
                let changed = existing.status != agent.status
                    || existing.paneTitle != agent.paneTitle
                    || existing.subagentCount != agent.subagentCount
                    || existing.currentToolName != agent.currentToolName
                    || existing.totalInputTokens != agent.totalInputTokens
                    || existing.totalOutputTokens != agent.totalOutputTokens
                    || existing.totalCacheCreationTokens != agent.totalCacheCreationTokens
                    || existing.totalCacheReadTokens != agent.totalCacheReadTokens
                    || existing.notificationMessage != agent.notificationMessage
                    || existing.transcriptPath != agent.transcriptPath
                if !changed { continue }
            }

            store.handleMessage(SocketMessage(
                type: .register,
                sessionId: agent.sessionId,
                cwd: agent.cwd,
                name: agent.name,
                avatarSeed: agent.avatarSeed,
                model: agent.model,
                status: agent.status,
                agentType: agent.agentType,
                inputTokens: agent.totalInputTokens > 0 ? agent.totalInputTokens : nil,
                outputTokens: agent.totalOutputTokens > 0 ? agent.totalOutputTokens : nil,
                cacheCreationTokens: agent.totalCacheCreationTokens > 0 ? agent.totalCacheCreationTokens : nil,
                cacheReadTokens: agent.totalCacheReadTokens > 0 ? agent.totalCacheReadTokens : nil
            ))
        }
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.connect()
            }
        }
    }

    // MARK: - HTTP API

    private func apiURL(_ path: String) -> URL? {
        guard let port = daemonPort, let token = daemonToken else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(path)?token=\(token)")
    }

    private func apiRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let url = apiURL(path) else {
            throw NSError(domain: "AgentHub", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Not connected to daemon"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "AgentHub", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: errorBody])
        }

        return data
    }

    func spawn(agentType: String, cwd: String, args: [String] = []) async throws -> [String: Any] {
        var body: [String: Any] = ["agentType": agentType, "cwd": cwd]
        if !args.isEmpty {
            body["flags"] = args
        }
        let data = try await apiRequest("/api/agents", method: "POST", body: body)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func kill(agentId: String) async throws {
        _ = try await apiRequest("/api/agents/\(agentId)", method: "DELETE")
    }

    func listAgents() async throws -> [[String: Any]] {
        let data = try await apiRequest("/api/agents")
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let agents = json["agents"] as? [[String: Any]] {
            return agents
        }
        return []
    }

    func health() async throws -> [String: Any] {
        let data = try await apiRequest("/api/health")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func refreshAgents() {
        Task {
            do {
                let data = try await apiRequest("/api/agents")
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let agents = try? decoder.decode([Agent].self, from: data) {
                    DispatchQueue.main.async { [weak self] in
                        self?.syncAgents(agents)
                    }
                } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let agentsJSON = json["agents"] {
                    guard let agentsData = try? JSONSerialization.data(withJSONObject: agentsJSON) else { return }
                    if let agents = try? decoder.decode([Agent].self, from: agentsData) {
                        DispatchQueue.main.async { [weak self] in
                            self?.syncAgents(agents)
                        }
                    }
                }
            } catch {
                print("[AgentHub] Failed to refresh agents: \(error)")
            }
        }
    }
}
