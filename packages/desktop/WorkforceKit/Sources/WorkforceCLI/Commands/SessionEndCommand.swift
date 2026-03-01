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
        let sessionId = resolveSessionId(from: event.sessionId)

        if let transcriptPath = event.transcriptPath {
            let usage = TranscriptParser.parseTokenUsage(from: transcriptPath)
            if usage.inputTokens > 0 || usage.outputTokens > 0 {
                APIClient.post(SocketMessage(
                    type: .updateTokens,
                    sessionId: sessionId,
                    cwd: event.cwd,
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    cacheCreationTokens: usage.cacheCreationTokens,
                    cacheReadTokens: usage.cacheReadTokens
                ))
            }
        }

        APIClient.post(SocketMessage(
            type: .deregister,
            sessionId: sessionId,
            cwd: event.cwd
        ))
    }
}
