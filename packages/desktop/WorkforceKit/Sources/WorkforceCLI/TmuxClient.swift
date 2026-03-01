import ArgumentParser
import Foundation
import WorkforceKit

enum TmuxClient {
    private static let tmuxPath: String? = {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func discoverAgents() -> [Agent] {
        let sessions = listSessions().filter { $0.hasPrefix("workforce-") }
        return sessions.map { session in
            let cwd = sessionCwd(session) ?? FileManager.default.currentDirectoryPath
            let title = paneTitle(session)
            return Agent(
                sessionId: session,
                name: session,
                avatarSeed: session,
                cwd: cwd,
                tmuxSession: session,
                status: .idle,
                paneTitle: title
            )
        }
    }

    static func attach(session: String) throws {
        guard let tmux = tmuxPath else {
            fputs("Error: tmux not found. Install with: brew install tmux\n", stderr)
            throw ExitCode(1)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["attach-session", "-t", session]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
    }

    private static func run(_ args: [String]) -> (status: Int32, output: String) {
        guard let path = tmuxPath else { return (1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        } catch { return (1, "") }
    }

    private static func listSessions() -> [String] {
        let result = run(["list-sessions", "-F", "#{session_name}"])
        guard result.status == 0, !result.output.isEmpty else { return [] }
        return result.output.split(separator: "\n").map(String.init)
    }

    private static func sessionCwd(_ name: String) -> String? {
        let result = run(["display-message", "-t", name, "-p", "#{pane_current_path}"])
        guard result.status == 0, !result.output.isEmpty else { return nil }
        return result.output
    }

    private static func paneTitle(_ name: String) -> String? {
        let result = run(["display-message", "-t", name, "-p", "#{pane_title}"])
        guard result.status == 0, !result.output.isEmpty else { return nil }
        return result.output
    }
}
