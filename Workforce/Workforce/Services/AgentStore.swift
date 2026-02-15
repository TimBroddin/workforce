import Foundation
import Observation

@Observable
final class AgentStore {
    var agents: [String: Agent] = [:]

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
                tmuxSession: message.tmuxSession,
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

        case .deregister:
            // Don't remove the agent if the tmux session is still alive
            // (e.g. /clear just ends the Claude session, not the terminal)
            if let agent = agents[message.sessionId],
               let tmux = agent.tmuxSession,
               tmuxSessionExists(tmux) {
                var updated = agent
                updated.status = .idle
                updated.currentToolName = nil
                updated.subagentCount = 0
                updated.lastActivityAt = message.timestamp
                agents[message.sessionId] = updated
            } else {
                agents.removeValue(forKey: message.sessionId)
            }
        }
    }

    /// Returns the existing agent for this session, or auto-registers one from the message.
    /// This handles events arriving from Claude sessions that weren't started via `workforce run`.
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
            tmuxSession: message.tmuxSession,
            status: message.status ?? .active
        )
        agents[message.sessionId] = agent
        return agent
    }

    @discardableResult
    func spawnAgent(cwd: String, agentType: String = "claude") -> String? {
        let timestamp = Int(Date().timeIntervalSince1970)
        let sessionName = "workforce-\(timestamp)"

        // Use a login shell so that the user's PATH is available (e.g. claude, bun, node)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = "\(agentType)"
        let result = runTmux([
            "new-session", "-d",
            "-s", sessionName,
            "-c", cwd,
            "-e", "WORKFORCE_SESSION=\(sessionName)",
            "--", shell, "-lc", command
        ])
        guard result.status == 0 else { return nil }

        let agent = Agent(
            sessionId: sessionName,
            name: NameGenerator.generate(from: sessionName),
            avatarSeed: sessionName,
            cwd: cwd,
            agentType: agentType,
            tmuxSession: sessionName,
            status: .idle
        )
        agents[sessionName] = agent
        return sessionName
    }

    func killAgent(_ sessionId: String) {
        guard let agent = agents[sessionId],
              let tmux = agent.tmuxSession else {
            agents.removeValue(forKey: sessionId)
            return
        }
        _ = runTmux(["kill-session", "-t", tmux])
        agents.removeValue(forKey: sessionId)
    }

    func removeAgent(_ sessionId: String) {
        agents.removeValue(forKey: sessionId)
    }

    func discoverTmuxSessions() {
        let sessions = listTmuxSessions().filter { $0.hasPrefix("workforce-") }
        for session in sessions {
            // Skip if we already know about this tmux session
            if agents.values.contains(where: { $0.tmuxSession == session }) { continue }

            let cwd = tmuxSessionCwd(session) ?? FileManager.default.currentDirectoryPath
            let agent = Agent(
                sessionId: session,
                name: NameGenerator.generate(from: session),
                avatarSeed: session,
                cwd: cwd,
                tmuxSession: session,
                status: .idle
            )
            agents[session] = agent
        }
    }

    func pruneStale() {
        for (id, agent) in agents {
            guard let tmux = agent.tmuxSession else { continue }
            if !tmuxSessionExists(tmux) {
                agents.removeValue(forKey: id)
            }
        }
    }

    func refreshPaneTitles() {
        for (id, var agent) in agents {
            guard let tmux = agent.tmuxSession else { continue }
            let title = tmuxPaneTitle(tmux)
            if agent.paneTitle != title {
                agent.paneTitle = title
                agents[id] = agent
            }
        }
    }

    private static let tmuxPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private func runTmux(_ arguments: [String]) -> (status: Int32, output: String) {
        guard let path = Self.tmuxPath else { return (1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (1, "")
        }
    }

    private func tmuxSessionExists(_ name: String) -> Bool {
        runTmux(["has-session", "-t", name]).status == 0
    }

    private func listTmuxSessions() -> [String] {
        let result = runTmux(["list-sessions", "-F", "#{session_name}"])
        guard result.status == 0, !result.output.isEmpty else { return [] }
        return result.output.split(separator: "\n").map(String.init)
    }

    private func tmuxSessionCwd(_ name: String) -> String? {
        let result = runTmux(["display-message", "-t", name, "-p", "#{pane_current_path}"])
        guard result.status == 0, !result.output.isEmpty else { return nil }
        return result.output
    }

    private func tmuxPaneTitle(_ name: String) -> String? {
        let result = runTmux(["display-message", "-t", name, "-p", "#{pane_title}"])
        guard result.status == 0, !result.output.isEmpty else { return nil }
        return result.output
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
