import ArgumentParser
import Foundation
import WorkforceKit

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Launch a coding agent in a tmux session"
    )

    @Option(name: .long, help: "Agent binary to launch (default: claude)")
    var agent: String = "claude"

    @Argument(parsing: .captureForPassthrough)
    var agentArgs: [String] = []

    func run() throws {
        // Resolve tmux path
        guard let tmuxPath = resolveBinary("tmux") else {
            throw ValidationError(
                "tmux not found. Install with: brew install tmux"
            )
        }

        // Resolve agent binary path
        guard let agentPath = resolveBinary(agent) else {
            throw ValidationError(
                "\(agent) not found. Make sure it is installed and in your PATH."
            )
        }

        // Generate session name
        let hexBytes = (0..<3).map { _ in UInt8.random(in: 0...255) }
        let hex = hexBytes.map { String(format: "%02x", $0) }.joined()
        let sessionName = "workforce-\(hex)"

        // Register agent with the Workforce app
        let cwd = FileManager.default.currentDirectoryPath
        let message = SocketMessage(
            type: .register,
            sessionId: sessionName,
            cwd: cwd,
            name: NameGenerator.generate(from: sessionName),
            avatarSeed: sessionName,
            status: .idle,
            agentType: agent,
            tmuxSession: sessionName
        )
        SocketClient.send(message)

        // Launch tmux directly with argv components to avoid shell escaping issues.
        // Set WORKFORCE_SESSION so hooks running inside this tmux session
        // can map Claude's session_id back to the workforce agent.
        let tmux = Process()
        tmux.executableURL = URL(fileURLWithPath: tmuxPath)
        tmux.arguments = [
            "new-session",
            "-s", sessionName,
            "-e", "WORKFORCE_SESSION=\(sessionName)",
            agentPath,
        ] + agentArgs
        tmux.standardInput = FileHandle.standardInput
        tmux.standardOutput = FileHandle.standardOutput
        tmux.standardError = FileHandle.standardError

        // Forward signals
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        try tmux.run()
        tmux.waitUntilExit()

        // Exit with tmux's exit code
        throw ExitCode(tmux.terminationStatus)
    }

    private func resolveBinary(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty else { return nil }
            return path
        } catch {
            return nil
        }
    }
}
