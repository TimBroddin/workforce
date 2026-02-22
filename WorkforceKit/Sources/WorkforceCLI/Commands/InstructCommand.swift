import ArgumentParser
import Foundation
import WorkforceKit

struct InstructCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "instruct",
        abstract: "Send a high-priority instruction to an agent"
    )

    @Argument(help: "Target session ID (or partial match)")
    var target: String

    @Argument(help: "Instruction text")
    var instruction: String

    @Flag(name: .long, help: "Also inject a tmux prompt to notify the agent immediately")
    var notify: Bool = false

    func run() throws {
        let fromSession = resolveCurrentSession()
        let toSession = try resolveTarget(target)

        let agentMessage = AgentMessage(
            from: fromSession,
            to: toSession,
            type: .instruction,
            priority: .high,
            subject: "Instruction",
            body: instruction
        )

        // Deliver to file-based mailbox
        try Mailbox.deliver(agentMessage)

        // Notify the Workforce app via socket
        SocketClient.send(SocketMessage(
            type: .agentMessage,
            sessionId: fromSession,
            cwd: FileManager.default.currentDirectoryPath,
            messageFrom: fromSession,
            messageTo: toSession,
            messageBody: instruction,
            messageSubject: "Instruction",
            messageType: "instruction",
            messagePriority: "high"
        ))

        print("Instruction sent to \(toSession)")

        // Optionally inject a tmux notification
        if notify {
            injectTmuxNotification(session: toSession)
        }
    }

    private func injectTmuxNotification(session: String) {
        let tmuxCandidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        guard let tmuxPath = tmuxCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            fputs("Warning: tmux not found, skipping notification injection\n", stderr)
            return
        }

        // Check if the tmux session exists
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: tmuxPath)
        checkProcess.arguments = ["has-session", "-t", session]
        checkProcess.standardOutput = FileHandle.nullDevice
        checkProcess.standardError = FileHandle.nullDevice
        do {
            try checkProcess.run()
            checkProcess.waitUntilExit()
            guard checkProcess.terminationStatus == 0 else {
                fputs("Warning: tmux session '\(session)' not found\n", stderr)
                return
            }
        } catch { return }

        // Send a notification prompt via tmux send-keys
        let prompt = "You have a new high-priority instruction. Run `workforce inbox` to read it."
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["send-keys", "-t", session, prompt, "C-m"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                print("Notification injected into tmux session")
            }
        } catch {
            fputs("Warning: failed to inject tmux notification\n", stderr)
        }
    }

    private func resolveCurrentSession() -> String {
        if let session = ProcessInfo.processInfo.environment["WORKFORCE_SESSION"] {
            return session
        }
        return "cli-\(ProcessInfo.processInfo.processIdentifier)"
    }

    private func resolveTarget(_ input: String) throws -> String {
        let agents = APIClient.fetchAgents() ?? TmuxClient.discoverAgents()

        if let agent = agents.first(where: { $0.sessionId == input }) {
            return agent.sessionId
        }

        let partialMatches = agents.filter { $0.sessionId.contains(input) }
        if partialMatches.count == 1 {
            return partialMatches[0].sessionId
        }

        let titleMatches = agents.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(input)
        }
        if titleMatches.count == 1 {
            return titleMatches[0].sessionId
        }

        if partialMatches.count > 1 || titleMatches.count > 1 {
            let matches = (partialMatches + titleMatches).map { "\($0.sessionId) (\($0.displayTitle))" }
            fputs("Ambiguous target. Matches:\n", stderr)
            for m in matches { fputs("  \(m)\n", stderr) }
            throw ExitCode(1)
        }

        return input
    }
}
