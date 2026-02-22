import ArgumentParser
import Foundation
import WorkforceKit

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message to another agent"
    )

    @Argument(help: "Target session ID (or partial match)")
    var target: String

    @Argument(help: "Message body")
    var message: String

    @Option(name: .long, help: "Message subject")
    var subject: String?

    @Option(name: .long, help: "Message type: message, artifact, status_update, work_request")
    var type: String = "message"

    @Option(name: .long, help: "Priority: low, normal, high")
    var priority: String = "normal"

    func run() throws {
        let fromSession = resolveCurrentSession()
        let toSession = try resolveTarget(target)

        let msgType = AgentMessage.MessageType(rawValue: type) ?? .message
        let msgPriority = AgentMessage.Priority(rawValue: priority) ?? .normal

        let agentMessage = AgentMessage(
            from: fromSession,
            to: toSession,
            type: msgType,
            priority: msgPriority,
            subject: subject,
            body: message
        )

        // Deliver to file-based mailbox
        try Mailbox.deliver(agentMessage)

        // Notify the Workforce app via socket
        SocketClient.send(SocketMessage(
            type: .agentMessage,
            sessionId: fromSession,
            cwd: FileManager.default.currentDirectoryPath,
            messageFrom: fromSession,
            messageTo: toSession,
            messageBody: message,
            messageSubject: subject,
            messageType: type,
            messagePriority: priority
        ))

        print("Message sent to \(toSession)")
    }

    /// Resolve the current agent's session ID.
    private func resolveCurrentSession() -> String {
        if let session = ProcessInfo.processInfo.environment["WORKFORCE_SESSION"] {
            return session
        }
        // Fall back to a generic identifier
        return "cli-\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// Resolve a target session ID, supporting partial matches via the API or tmux discovery.
    private func resolveTarget(_ input: String) throws -> String {
        // If it's an exact session ID, use it directly
        let agents = APIClient.fetchAgents() ?? TmuxClient.discoverAgents()

        // Exact match
        if let agent = agents.first(where: { $0.sessionId == input }) {
            return agent.sessionId
        }

        // Partial match on session ID
        let partialMatches = agents.filter { $0.sessionId.contains(input) }
        if partialMatches.count == 1 {
            return partialMatches[0].sessionId
        }

        // Match by display title
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

        // No match found — still allow sending (the mailbox will be created)
        return input
    }
}
