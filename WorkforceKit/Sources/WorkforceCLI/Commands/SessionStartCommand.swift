import ArgumentParser
import Foundation
import WorkforceKit

struct SessionStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-start",
        abstract: "Handle SessionStart hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(HookEventBase.self, from: data)
        SocketClient.send(SocketMessage(
            type: .updateStatus,
            sessionId: resolveSessionId(from: event.sessionId),
            cwd: event.cwd,
            status: .active
        ))
    }
}
