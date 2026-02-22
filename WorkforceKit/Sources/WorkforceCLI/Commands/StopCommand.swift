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

        // Check mailbox for unread messages and notify via tmux if any
        let unreadCount = Mailbox.unreadCount(for: sessionId)
        if unreadCount > 0 {
            notifyViaTmux(
                session: sessionId,
                prompt: "You have \(unreadCount) unread message\(unreadCount == 1 ? "" : "s") from other agents. Run `workforce inbox` to read them."
            )
        }
    }

    private func notifyViaTmux(session: String, prompt: String) {
        let tmuxCandidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        guard let tmuxPath = tmuxCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }

        // Verify the tmux session exists
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: tmuxPath)
        checkProcess.arguments = ["has-session", "-t", session]
        checkProcess.standardOutput = FileHandle.nullDevice
        checkProcess.standardError = FileHandle.nullDevice
        do {
            try checkProcess.run()
            checkProcess.waitUntilExit()
            guard checkProcess.terminationStatus == 0 else { return }
        } catch { return }

        // Inject the notification
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["send-keys", "-t", session, prompt, "C-m"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Silently fail — don't disrupt the hook
        }
    }
}
