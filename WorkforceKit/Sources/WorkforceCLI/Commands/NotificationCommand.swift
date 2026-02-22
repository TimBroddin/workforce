import ArgumentParser
import Foundation
import WorkforceKit

struct NotificationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notification",
        abstract: "Handle Notification hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(NotificationEvent.self, from: data)
        let status: AgentStatus = event.type == "permission_prompt"
            ? .waitingForPermission
            : .waitingForInput
        SocketClient.send(SocketMessage(
            type: .notification,
            sessionId: resolveSessionId(from: event.sessionId),
            cwd: event.cwd,
            status: status,
            notificationType: event.type,
            transcriptPath: event.transcriptPath
        ))
    }
}
