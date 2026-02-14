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
        let event = try JSONDecoder().decode(SessionStartEvent.self, from: data)
        let host = HostDetection.detect()

        let message = SocketMessage(
            type: .register,
            sessionId: event.sessionId,
            cwd: event.cwd,
            name: NameGenerator.generate(from: event.sessionId),
            avatarSeed: event.sessionId,
            hostApp: host.app,
            hostBundleId: host.bundleId,
            hostPid: host.pid,
            status: .active
        )
        SocketClient.send(message)
    }
}
