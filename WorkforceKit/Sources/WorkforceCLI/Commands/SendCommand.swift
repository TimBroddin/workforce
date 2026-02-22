import ArgumentParser
import Foundation
import WorkforceKit

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message to another agent or broadcast to all"
    )

    @Argument(help: "Target session ID (or partial match). Ignored when --broadcast or --project is used.")
    var target: String?

    @Argument(help: "Message body")
    var message: String

    @Option(name: .long, help: "Message subject")
    var subject: String?

    @Option(name: .long, help: "Message type: message, artifact, status_update, work_request")
    var type: String = "message"

    @Option(name: .long, help: "Priority: low, normal, high")
    var priority: String = "normal"

    @Flag(name: .long, help: "Broadcast to all agents globally (current and future)")
    var broadcast: Bool = false

    @Flag(name: .long, help: "Broadcast to all agents in the current project directory")
    var project: Bool = false

    func validate() throws {
        if !broadcast && !project && target == nil {
            throw ValidationError("Provide a target session ID, or use --broadcast / --project")
        }
    }

    func run() throws {
        let fromSession = resolveCurrentSession()
        let msgType = AgentMessage.MessageType(rawValue: type) ?? .message
        let msgPriority = AgentMessage.Priority(rawValue: priority) ?? .normal
        let cwd = FileManager.default.currentDirectoryPath

        if broadcast || project {
            let broadcastTo = broadcast ? "broadcast:global" : "broadcast:project"
            let agentMessage = AgentMessage(
                from: fromSession,
                to: broadcastTo,
                type: msgType,
                priority: msgPriority,
                subject: subject,
                body: message
            )

            if broadcast {
                try Mailbox.broadcastGlobal(agentMessage)
                print("Message broadcast globally")
            }
            if project {
                let projectMessage = AgentMessage(
                    from: fromSession,
                    to: "broadcast:project",
                    type: msgType,
                    priority: msgPriority,
                    subject: subject,
                    body: message
                )
                try Mailbox.broadcastToProject(cwd: cwd, projectMessage)
                print("Message broadcast to project: \(cwd)")
            }

            // Notify the Workforce app
            SocketClient.send(SocketMessage(
                type: .agentMessage,
                sessionId: fromSession,
                cwd: cwd,
                messageFrom: fromSession,
                messageTo: broadcast ? "broadcast:global" : "broadcast:project",
                messageBody: message,
                messageSubject: subject,
                messageType: type,
                messagePriority: priority
            ))
        } else {
            let toSession = try resolveTarget(target!)

            let agentMessage = AgentMessage(
                from: fromSession,
                to: toSession,
                type: msgType,
                priority: msgPriority,
                subject: subject,
                body: message
            )

            try Mailbox.deliver(agentMessage)

            SocketClient.send(SocketMessage(
                type: .agentMessage,
                sessionId: fromSession,
                cwd: cwd,
                messageFrom: fromSession,
                messageTo: toSession,
                messageBody: message,
                messageSubject: subject,
                messageType: type,
                messagePriority: priority
            ))

            print("Message sent to \(toSession)")
        }
    }

    private func resolveCurrentSession() -> String {
        if let session = ProcessInfo.processInfo.environment["WORKFORCE_SESSION"] {
            return session
        }
        return "cli-\(ProcessInfo.processInfo.processIdentifier)"
    }

    private func resolveTarget(_ input: String) throws -> String {
        let agents = APIClient.fetchAgents() ?? TmuxClient.discoverAgents()

        if let agent = agents.first(where: { $0.sessionId == input }) {
            return agent.sessionId
        }

        let partialMatches = agents.filter { $0.sessionId.contains(input) }
        if partialMatches.count == 1 {
            return partialMatches[0].sessionId
        }

        let titleMatches = agents.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(input)
        }
        if titleMatches.count == 1 {
            return titleMatches[0].sessionId
        }

        if partialMatches.count > 1 || titleMatches.count > 1 {
            let matches = (partialMatches + titleMatches).map { "\($0.sessionId) (\($0.displayTitle))" }
            fputs("Ambiguous target. Matches:\n", stderr)
            for m in matches { fputs("  \(m)\n", stderr) }
            throw ExitCode(1)
        }

        return input
    }
}
