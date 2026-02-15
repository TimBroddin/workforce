import ArgumentParser
import Foundation
import WorkforceKit

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Handle Stop hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(HookEventBase.self, from: data)
        SocketClient.send(SocketMessage(
            type: .updateStatus,
            sessionId: resolveSessionId(from: event.sessionId),
            cwd: event.cwd,
            status: .idle
        ))
    }
}
