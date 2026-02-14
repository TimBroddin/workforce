import ArgumentParser
import Foundation
import WorkforceKit

struct PreToolUseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pre-tool-use",
        abstract: "Handle PreToolUse hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(ToolUseEvent.self, from: data)
        SocketClient.send(SocketMessage(
            type: .updateTool,
            sessionId: event.sessionId,
            cwd: event.cwd,
            status: .active,
            toolName: event.toolName
        ))
    }
}

struct PostToolUseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post-tool-use",
        abstract: "Handle PostToolUse hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(ToolUseEvent.self, from: data)
        SocketClient.send(SocketMessage(
            type: .updateTool,
            sessionId: event.sessionId,
            cwd: event.cwd,
            status: .active,
            toolName: nil
        ))
    }
}

struct PostToolUseFailureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post-tool-use-failure",
        abstract: "Handle PostToolUseFailure hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(ToolUseEvent.self, from: data)
        SocketClient.send(SocketMessage(
            type: .updateTool,
            sessionId: event.sessionId,
            cwd: event.cwd,
            status: .active,
            toolName: nil
        ))
    }
}
