import ArgumentParser
import Foundation
import WorkforceKit

struct AttachCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach to an agent's tmux session"
    )

    @Argument(help: "Session name or partial ID (e.g. 'workforce-a1b2c3' or 'a1b2c3')")
    var target: String

    func run() throws {
        let agents = APIClient.fetchAgents() ?? TmuxClient.discoverAgents()

        let matches = agents.filter { agent in
            agent.sessionId == target
            || agent.sessionId == "workforce-\(target)"
            || agent.tmuxSession == target
            || agent.sessionId.hasSuffix(target)
        }

        guard !matches.isEmpty else {
            throw ValidationError("No session matching '\(target)'. Run 'workforce list' to see available sessions.")
        }

        guard matches.count == 1 else {
            var message = "Multiple sessions match '\(target)':\n"
            for agent in matches {
                message += "  \(agent.sessionId)\n"
            }
            message += "Please be more specific."
            throw ValidationError(message)
        }

        let agent = matches[0]
        let tmuxSession = agent.tmuxSession ?? agent.sessionId

        try TmuxClient.attach(session: tmuxSession)
    }
}
