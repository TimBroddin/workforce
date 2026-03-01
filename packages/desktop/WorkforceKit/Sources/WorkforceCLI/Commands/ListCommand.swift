import ArgumentParser
import Foundation
import WorkforceKit

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all active agent sessions"
    )

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() throws {
        let agents = APIClient.fetchAgents() ?? TmuxClient.discoverAgents()

        if agents.isEmpty {
            print("No active sessions.")
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(agents)
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }

        printTable(agents)
    }

    private func printTable(_ agents: [Agent]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        struct Row {
            let session: String
            let agent: String
            let status: String
            let cwd: String
            let title: String
        }

        let rows = agents.map { agent in
            let shortCwd = agent.cwd.hasPrefix(home)
                ? "~" + agent.cwd.dropFirst(home.count)
                : agent.cwd
            return Row(
                session: agent.sessionId,
                agent: agent.agentType,
                status: agent.status.rawValue,
                cwd: String(shortCwd),
                title: agent.displayTitle
            )
        }

        let colSession = max(7, rows.map(\.session.count).max() ?? 0)
        let colAgent   = max(5, rows.map(\.agent.count).max() ?? 0)
        let colStatus  = max(6, rows.map(\.status.count).max() ?? 0)
        let colCwd     = max(3, rows.map(\.cwd.count).max() ?? 0)

        let header = [
            "SESSION".padding(toLength: colSession, withPad: " ", startingAt: 0),
            "AGENT".padding(toLength: colAgent, withPad: " ", startingAt: 0),
            "STATUS".padding(toLength: colStatus, withPad: " ", startingAt: 0),
            "CWD".padding(toLength: colCwd, withPad: " ", startingAt: 0),
            "TITLE",
        ].joined(separator: "  ")
        print(header)

        for row in rows {
            let line = [
                row.session.padding(toLength: colSession, withPad: " ", startingAt: 0),
                row.agent.padding(toLength: colAgent, withPad: " ", startingAt: 0),
                row.status.padding(toLength: colStatus, withPad: " ", startingAt: 0),
                row.cwd.padding(toLength: colCwd, withPad: " ", startingAt: 0),
                row.title,
            ].joined(separator: "  ")
            print(line)
        }
    }
}
