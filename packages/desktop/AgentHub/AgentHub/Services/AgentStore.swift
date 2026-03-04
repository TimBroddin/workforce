import Foundation
import Observation

@Observable
final class AgentStore {
    var agents: [String: Agent] = [:]
    var onStateChange: ((SocketMessage) -> Void)?

    private static let storePath: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AgentHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agents.json")
    }()

    var sortedAgents: [Agent] {
        agents.values.sorted { a, b in
            a.startedAt < b.startedAt
        }
    }

    func handleMessage(_ message: SocketMessage) {
        switch message.type {
        case .register:
            let agent = Agent(
                sessionId: message.sessionId,
                name: message.name ?? NameGenerator.generate(from: message.sessionId),
                avatarSeed: message.avatarSeed ?? message.sessionId,
                cwd: message.cwd,
                agentType: message.agentType ?? "claude",
                model: message.model,
                status: message.status ?? .idle
            )
            agents[message.sessionId] = agent

        case .updateStatus:
            var agent = ensureAgent(for: message)
            agent.lastActivityAt = message.timestamp
            if let status = message.status { agent.status = status }
            agents[message.sessionId] = agent

        case .updateTool:
            var agent = ensureAgent(for: message)
            agent.lastActivityAt = message.timestamp
            agent.currentToolName = message.toolName
            if let status = message.status { agent.status = status }
            agents[message.sessionId] = agent

        case .notification:
            var agent = ensureAgent(for: message)
            let previousStatus = agent.status
            agent.lastActivityAt = message.timestamp
            agent.lastNotificationType = message.notificationType
            if let path = message.transcriptPath { agent.transcriptPath = path }
            if let msg = message.notificationMessage { agent.notificationMessage = msg }
            if let status = message.status { agent.status = status }
            agents[message.sessionId] = agent
            NotificationManager.shared.notifyIfNeeded(agent: agent, previousStatus: previousStatus)

        case .subagentStart:
            var agent = ensureAgent(for: message)
            agent.lastActivityAt = message.timestamp
            agent.subagentCount += 1
            agents[message.sessionId] = agent

        case .subagentStop:
            var agent = ensureAgent(for: message)
            agent.lastActivityAt = message.timestamp
            agent.subagentCount = max(0, agent.subagentCount - 1)
            agents[message.sessionId] = agent

        case .updateTokens:
            var agent = ensureAgent(for: message)
            agent.lastActivityAt = message.timestamp
            if let input = message.inputTokens { agent.totalInputTokens = input }
            if let output = message.outputTokens { agent.totalOutputTokens = output }
            if let cacheCreation = message.cacheCreationTokens { agent.totalCacheCreationTokens = cacheCreation }
            if let cacheRead = message.cacheReadTokens { agent.totalCacheReadTokens = cacheRead }
            agents[message.sessionId] = agent

        case .deregister:
            agents.removeValue(forKey: message.sessionId)
        }
        save()
        onStateChange?(message)
    }

    /// Returns the existing agent for this session, or auto-registers one from the message.
    /// This handles events arriving from Claude sessions that weren't started via the daemon.
    private func ensureAgent(for message: SocketMessage) -> Agent {
        if let existing = agents[message.sessionId] {
            return existing
        }
        let agent = Agent(
            sessionId: message.sessionId,
            name: message.name ?? NameGenerator.generate(from: message.sessionId),
            avatarSeed: message.sessionId,
            cwd: message.cwd,
            agentType: message.agentType ?? "claude",
            model: message.model,
            status: message.status ?? .active
        )
        agents[message.sessionId] = agent
        return agent
    }

    func removeAgent(_ sessionId: String) {
        let cwd = agents[sessionId]?.cwd ?? ""
        agents.removeValue(forKey: sessionId)
        save()
        onStateChange?(SocketMessage(type: .deregister, sessionId: sessionId, cwd: cwd))
    }

    // MARK: - Daemon Sync

    /// Syncs the local agents dictionary from the daemon's agent list.
    /// Parses daemon agent data into local Agent objects, updates existing agents,
    /// adds new ones, and removes agents no longer in the daemon's list.
    func syncAgentsFromDaemon(_ agentsData: [[String: Any]]) {
        var daemonIds = Set<String>()

        for data in agentsData {
            guard let sessionId = data["sessionId"] as? String ?? data["id"] as? String else { continue }
            daemonIds.insert(sessionId)

            let cwd = data["cwd"] as? String ?? ""
            let agentType = data["agentType"] as? String ?? "claude"
            let name = data["name"] as? String ?? NameGenerator.generate(from: sessionId)
            let avatarSeed = data["avatarSeed"] as? String ?? sessionId
            let model = data["model"] as? String
            let statusRaw = data["status"] as? String ?? "idle"
            let status = AgentStatus(rawValue: statusRaw) ?? .idle
            let toolName = data["currentToolName"] as? String
            let subagentCount = data["subagentCount"] as? Int ?? 0
            let paneTitle = data["paneTitle"] as? String
            let transcriptPath = data["transcriptPath"] as? String
            let notificationMessage = data["notificationMessage"] as? String
            let inputTokens = data["totalInputTokens"] as? Int ?? 0
            let outputTokens = data["totalOutputTokens"] as? Int ?? 0
            let cacheCreationTokens = data["totalCacheCreationTokens"] as? Int ?? 0
            let cacheReadTokens = data["totalCacheReadTokens"] as? Int ?? 0

            if var existing = agents[sessionId] {
                // Update existing agent with latest daemon state
                existing.status = status
                existing.currentToolName = toolName
                existing.subagentCount = subagentCount
                existing.paneTitle = paneTitle
                existing.lastActivityAt = Date()
                if inputTokens > 0 { existing.totalInputTokens = inputTokens }
                if outputTokens > 0 { existing.totalOutputTokens = outputTokens }
                if cacheCreationTokens > 0 { existing.totalCacheCreationTokens = cacheCreationTokens }
                if cacheReadTokens > 0 { existing.totalCacheReadTokens = cacheReadTokens }
                if let path = transcriptPath { existing.transcriptPath = path }
                if let msg = notificationMessage { existing.notificationMessage = msg }
                agents[sessionId] = existing
            } else {
                // Add new agent from daemon
                let agent = Agent(
                    sessionId: sessionId,
                    name: name,
                    avatarSeed: avatarSeed,
                    cwd: cwd,
                    agentType: agentType,
                    model: model,
                    status: status,
                    currentToolName: toolName,
                    subagentCount: subagentCount,
                    paneTitle: paneTitle,
                    transcriptPath: transcriptPath,
                    notificationMessage: notificationMessage,
                    totalInputTokens: inputTokens,
                    totalOutputTokens: outputTokens,
                    totalCacheCreationTokens: cacheCreationTokens,
                    totalCacheReadTokens: cacheReadTokens
                )
                agents[sessionId] = agent
            }
        }

        // Remove agents that are no longer in the daemon's list
        let staleIds = Set(agents.keys).subtracting(daemonIds)
        for id in staleIds {
            agents.removeValue(forKey: id)
        }

        save()
    }

    /// Processes daemon events (agent-started, agent-stopped, agent-output, session-end).
    func handleDaemonEvent(_ event: [String: Any]) {
        guard let eventType = event["type"] as? String else { return }
        let sessionId = event["sessionId"] as? String ?? event["id"] as? String ?? ""
        let cwd = event["cwd"] as? String ?? agents[sessionId]?.cwd ?? ""

        switch eventType {
        case "agent-started":
            let agentType = event["agentType"] as? String ?? "claude"
            let name = event["name"] as? String ?? NameGenerator.generate(from: sessionId)
            let avatarSeed = event["avatarSeed"] as? String ?? sessionId
            let model = event["model"] as? String

            let agent = Agent(
                sessionId: sessionId,
                name: name,
                avatarSeed: avatarSeed,
                cwd: cwd,
                agentType: agentType,
                model: model,
                status: .idle
            )
            agents[sessionId] = agent
            save()
            onStateChange?(SocketMessage(type: .register, sessionId: sessionId, cwd: cwd, agentType: agentType))

        case "agent-stopped":
            let agentCwd = agents[sessionId]?.cwd ?? cwd
            agents.removeValue(forKey: sessionId)
            save()
            onStateChange?(SocketMessage(type: .deregister, sessionId: sessionId, cwd: agentCwd))

        case "agent-output":
            // Agent output events can carry status/tool updates
            if var agent = agents[sessionId] {
                agent.lastActivityAt = Date()
                if let statusRaw = event["status"] as? String,
                   let status = AgentStatus(rawValue: statusRaw) {
                    agent.status = status
                }
                if let toolName = event["toolName"] as? String {
                    agent.currentToolName = toolName
                }
                agents[sessionId] = agent
                save()
            }

        case "session-end":
            let agentCwd = agents[sessionId]?.cwd ?? cwd
            if var agent = agents[sessionId] {
                agent.status = .stopped
                agent.lastActivityAt = Date()
                agents[sessionId] = agent
                save()
                onStateChange?(SocketMessage(type: .deregister, sessionId: sessionId, cwd: agentCwd))
            }

        default:
            break
        }
    }

    // MARK: - Persistence

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(agents.values)) else { return }
        try? data.write(to: Self.storePath, options: .atomic)
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.storePath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode([Agent].self, from: data) else { return }
        for agent in saved {
            if agents[agent.sessionId] == nil {
                agents[agent.sessionId] = agent
            } else {
                // Merge token data from persisted state into existing agent
                var existing = agents[agent.sessionId]!
                if existing.totalInputTokens == 0 { existing.totalInputTokens = agent.totalInputTokens }
                if existing.totalOutputTokens == 0 { existing.totalOutputTokens = agent.totalOutputTokens }
                if existing.totalCacheCreationTokens == 0 { existing.totalCacheCreationTokens = agent.totalCacheCreationTokens }
                if existing.totalCacheReadTokens == 0 { existing.totalCacheReadTokens = agent.totalCacheReadTokens }
                agents[agent.sessionId] = existing
            }
        }
    }

    private func statusPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingForPermission: 0
        case .waitingForInput: 1
        case .active: 2
        case .idle: 3
        case .stopped: 4
        case .orphaned: 5
        }
    }
}
