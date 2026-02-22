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
        let sessionId = resolveSessionId(from: event.sessionId)

        SocketClient.send(SocketMessage(
            type: .updateStatus,
            sessionId: sessionId,
            cwd: event.cwd,
            status: .idle
        ))

        if let transcriptPath = event.transcriptPath {
            let usage = TranscriptParser.parseTokenUsage(from: transcriptPath)
            if usage.inputTokens > 0 || usage.outputTokens > 0 {
                SocketClient.send(SocketMessage(
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
    }
}
