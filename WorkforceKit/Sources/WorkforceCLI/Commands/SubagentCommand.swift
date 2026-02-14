import ArgumentParser
import Foundation
import WorkforceKit

struct SubagentStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subagent-start",
        abstract: "Handle SubagentStart hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(SubagentEvent.self, from: data)
        SocketClient.send(SocketMessage(
            type: .subagentStart,
            sessionId: event.sessionId,
            cwd: event.cwd,
            status: .active,
            agentType: event.agentType
        ))
    }
}

struct SubagentStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subagent-stop",
        abstract: "Handle SubagentStop hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(SubagentEvent.self, from: data)
        SocketClient.send(SocketMessage(
            type: .subagentStop,
            sessionId: event.sessionId,
            cwd: event.cwd,
            agentType: event.agentType
        ))
    }
}
