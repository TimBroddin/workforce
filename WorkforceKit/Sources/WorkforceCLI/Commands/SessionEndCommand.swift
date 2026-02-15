import ArgumentParser
import Foundation
import WorkforceKit

struct SessionEndCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-end",
        abstract: "Handle SessionEnd hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(HookEventBase.self, from: data)
        SocketClient.send(SocketMessage(
            type: .deregister,
            sessionId: resolveSessionId(from: event.sessionId),
            cwd: event.cwd
        ))
    }
}
