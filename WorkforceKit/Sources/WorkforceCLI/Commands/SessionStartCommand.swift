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
        let tmux = detectTmuxSession()

        let message = SocketMessage(
            type: .register,
            sessionId: event.sessionId,
            cwd: event.cwd,
            name: NameGenerator.generate(from: event.sessionId),
            avatarSeed: event.sessionId,
            hostApp: host.app,
            hostBundleId: host.bundleId,
            hostPid: host.pid,
            model: event.model,
            status: .active,
            tmuxSession: tmux
        )
        SocketClient.send(message)
    }

    private func detectTmuxSession() -> String? {
        guard ProcessInfo.processInfo.environment["TMUX"] != nil else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "display-message", "-p", "#{session_name}"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let name = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return name?.isEmpty == true ? nil : name
        } catch {
            return nil
        }
    }
}
