import Foundation
import Observation

@Observable
final class AgentStore {
    var agents: [String: Agent] = [:]

    var sortedAgents: [Agent] {
        agents.values.sorted { a, b in
            let aPriority = statusPriority(a.status)
            let bPriority = statusPriority(b.status)
            if aPriority != bPriority { return aPriority < bPriority }
            return a.lastActivityAt > b.lastActivityAt
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
                hostApp: message.hostApp ?? .unknown,
                hostBundleId: message.hostBundleId,
                hostPid: message.hostPid,
                status: message.status ?? .active
            )
            agents[message.sessionId] = agent

        case .updateStatus:
            guard var agent = agents[message.sessionId] else {
                registerMinimal(from: message)
                return
            }
            agent.lastActivityAt = message.timestamp
            if let status = message.status { agent.status = status }
            agents[message.sessionId] = agent

        case .updateTool:
            guard var agent = agents[message.sessionId] else {
                registerMinimal(from: message)
                return
            }
            agent.lastActivityAt = message.timestamp
            agent.currentToolName = message.toolName
            if let status = message.status { agent.status = status }
            agents[message.sessionId] = agent

        case .notification:
            guard var agent = agents[message.sessionId] else {
                registerMinimal(from: message)
                return
            }
            agent.lastActivityAt = message.timestamp
            agent.lastNotificationType = message.notificationType
            if let status = message.status { agent.status = status }
            agents[message.sessionId] = agent

        case .subagentStart:
            guard var agent = agents[message.sessionId] else {
                registerMinimal(from: message)
                return
            }
            agent.lastActivityAt = message.timestamp
            agent.subagentCount += 1
            agents[message.sessionId] = agent

        case .subagentStop:
            guard var agent = agents[message.sessionId] else { return }
            agent.lastActivityAt = message.timestamp
            agent.subagentCount = max(0, agent.subagentCount - 1)
            agents[message.sessionId] = agent

        case .deregister:
            agents.removeValue(forKey: message.sessionId)
        }
    }

    func pruneStale() {
        let cutoff = Date().addingTimeInterval(-300)
        for (id, agent) in agents {
            if agent.lastActivityAt < cutoff && agent.status != .stopped {
                agents.removeValue(forKey: id)
            }
        }
    }

    private func registerMinimal(from message: SocketMessage) {
        let agent = Agent(
            sessionId: message.sessionId,
            name: NameGenerator.generate(from: message.sessionId),
            avatarSeed: message.sessionId,
            cwd: message.cwd,
            hostApp: message.hostApp ?? .unknown,
            hostBundleId: message.hostBundleId,
            hostPid: message.hostPid,
            status: message.status ?? .active,
            currentToolName: message.toolName
        )
        agents[message.sessionId] = agent
    }

    private func statusPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingForPermission: 0
        case .waitingForInput: 1
        case .active: 2
        case .idle: 3
        case .stopped: 4
        }
    }
}
