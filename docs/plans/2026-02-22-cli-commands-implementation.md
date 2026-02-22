# CLI Commands (list, attach, tui) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `workforce list`, `workforce attach`, and `workforce tui` subcommands so users can discover and connect to agent sessions from the terminal.

**Architecture:** The Workforce macOS app exposes agent state via a new HTTP server on localhost. The CLI queries this API (falling back to raw tmux queries). Three new ArgumentParser subcommands provide table output, direct attach, and an ncurses TUI.

**Tech Stack:** Swift, NWListener (HTTP), Darwin.ncurses, ArgumentParser

---

### Task 1: Add `paneTitle` and `displayTitle` to the shared WorkforceKit Agent model

The app's Agent model (in `Workforce/Workforce/Models/Agent.swift`) has `paneTitle` and `displayTitle` but the shared `WorkforceKit` model doesn't. The HTTP API will serialize the app's model, and the CLI needs to decode it. Sync these.

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceKit/Models/Agent.swift`

**Step 1: Add paneTitle property and displayTitle computed property**

Add `paneTitle` to the stored properties and `displayTitle` as a computed property. Mirror the logic from `Workforce/Workforce/Models/Agent.swift:33-46`.

```swift
// Add after line 29 (after subagentCount):
public var paneTitle: String?

/// User-facing title for the agent, preferring meaningful pane titles.
public var displayTitle: String {
    let title: String? = paneTitle.flatMap { paneTitle in
        let trimmed = paneTitle.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if Self.ignoredPaneTitles.contains(trimmed.lowercased()) { return nil }
        if !trimmed.contains(" "), trimmed.contains(".") { return nil }
        return trimmed
    }
    let raw = title ?? agentType.capitalized
    if raw.count > 2, raw.hasPrefix("_ ") {
        return String(raw.dropFirst(2))
    }
    return raw
}

private static let ignoredPaneTitles: Set<String> = [
    "node", "bash", "zsh", "sh", "fish", "python", "python3", "ruby",
    "bun", "deno", "npx", "tsx",
]
```

Update the `init` to accept `paneTitle`:

```swift
public init(
    // ... existing params ...,
    subagentCount: Int = 0,
    paneTitle: String? = nil  // ADD THIS
) {
    // ... existing assignments ...
    self.paneTitle = paneTitle  // ADD THIS
}
```

**Step 2: Remove duplicate Agent model from the app**

Once `WorkforceKit.Agent` has parity, delete `Workforce/Workforce/Models/Agent.swift` and have the app import `WorkforceKit.Agent` instead. The app already imports WorkforceKit indirectly through the Xcode project. If this causes build issues, keep both but ensure `paneTitle`/`displayTitle` exist in the shared model.

> **Note:** This may need careful checking — the Xcode project may reference the app's local Agent.swift. If so, just update the shared model and leave the app's model as-is for now. The HTTP API uses the app's model for serialization anyway.

**Step 3: Build to verify**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add WorkforceKit/Sources/WorkforceKit/Models/Agent.swift
git commit -m "feat: add paneTitle and displayTitle to shared Agent model"
```

---

### Task 2: HTTP API Server in the macOS app

**Files:**
- Create: `Workforce/Workforce/Services/HTTPServer.swift`
- Modify: `Workforce/Workforce/WorkforceApp.swift`

**Step 1: Create HTTPServer.swift**

A minimal HTTP server using `NWListener` on a TCP port. Parses GET requests, returns JSON.

```swift
import Foundation
import Network

final class HTTPServer {
    private var listener: NWListener?
    private let store: AgentStore
    private let portFilePath: String

    init(store: AgentStore) {
        self.store = store
        self.portFilePath = "/tmp/workforce-\(getuid()).port"
    }

    func start() throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: .any)

        listener?.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener?.port {
                self?.writePortFile(port: port.rawValue)
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        try? FileManager.default.removeItem(atPath: portFilePath)
    }

    private func writePortFile(port: UInt16) {
        try? "\(port)".write(toFile: portFilePath, atomically: true, encoding: .utf8)
        NSLog("[Workforce] HTTP API listening on port %d", port)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, _, _ in
            guard let self, let content,
                  let request = String(data: content, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let response = self.route(request)
            let httpResponse = "HTTP/1.1 \(response.status)\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n\(response.body)"
            connection.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private struct HTTPResponse {
        let status: String
        let body: String
    }

    private func route(_ request: String) -> HTTPResponse {
        let firstLine = request.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return HTTPResponse(status: "405 Method Not Allowed", body: "{\"error\":\"method not allowed\"}")
        }

        let path = String(parts[1])

        if path == "/api/agents" {
            return listAgents()
        }

        if path.hasPrefix("/api/agents/") {
            let id = String(path.dropFirst("/api/agents/".count))
            return getAgent(id: id)
        }

        return HTTPResponse(status: "404 Not Found", body: "{\"error\":\"not found\"}")
    }

    private func listAgents() -> HTTPResponse {
        let agents = store.sortedAgents
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(agents),
              let json = String(data: data, encoding: .utf8) else {
            return HTTPResponse(status: "500 Internal Server Error", body: "{\"error\":\"encode failed\"}")
        }
        return HTTPResponse(status: "200 OK", body: json)
    }

    private func getAgent(id: String) -> HTTPResponse {
        guard let agent = store.agents[id] else {
            return HTTPResponse(status: "404 Not Found", body: "{\"error\":\"agent not found\"}")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(agent),
              let json = String(data: data, encoding: .utf8) else {
            return HTTPResponse(status: "500 Internal Server Error", body: "{\"error\":\"encode failed\"}")
        }
        return HTTPResponse(status: "200 OK", body: json)
    }
}
```

**Step 2: Start HTTP server in WorkforceApp.swift**

Add alongside the existing socket server. Modify `WorkforceApp.swift`:

```swift
// Add property:
@State private var httpServer: HTTPServer?

// In init(), after `try? server.start()`:
let http = HTTPServer(store: store)
_httpServer = State(initialValue: http)
try? http.start()
```

**Step 3: Build and run the app to verify**

Build the Xcode project. Check that `/tmp/workforce-<uid>.port` appears with a port number. Test with:
```bash
curl http://localhost:$(cat /tmp/workforce-$(id -u).port)/api/agents
```
Expected: JSON array (possibly empty `[]`)

**Step 4: Commit**

```bash
git add Workforce/Workforce/Services/HTTPServer.swift Workforce/Workforce/WorkforceApp.swift
git commit -m "feat: add HTTP API server for agent state queries"
```

---

### Task 3: API Client and Tmux Fallback for the CLI

**Files:**
- Create: `WorkforceKit/Sources/WorkforceCLI/APIClient.swift`
- Create: `WorkforceKit/Sources/WorkforceCLI/TmuxClient.swift`

**Step 1: Create APIClient.swift**

Reads the port file, makes synchronous HTTP GET, decodes Agent JSON.

```swift
import Foundation
import WorkforceKit

enum APIClient {
    private static let portFilePath = "/tmp/workforce-\(getuid()).port"

    static func fetchAgents() -> [Agent]? {
        guard let port = readPort() else { return nil }
        guard let url = URL(string: "http://localhost:\(port)/api/agents") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        let semaphore = DispatchSemaphore(value: 0)
        var result: [Agent]?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data, error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            result = try? decoder.decode([Agent].self, from: data)
        }
        task.resume()
        semaphore.wait()
        return result
    }

    private static func readPort() -> UInt16? {
        guard let content = try? String(contentsOfFile: portFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let port = UInt16(content) else { return nil }
        return port
    }
}
```

**Step 2: Create TmuxClient.swift**

Fallback: queries tmux directly for workforce-* sessions.

```swift
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
            throw ValidationError("tmux not found. Install with: brew install tmux")
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
```

**Step 3: Build to verify**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Expected: Build succeeds (no callers yet, just compiles)

**Step 4: Commit**

```bash
git add WorkforceKit/Sources/WorkforceCLI/APIClient.swift WorkforceKit/Sources/WorkforceCLI/TmuxClient.swift
git commit -m "feat: add API client and tmux fallback for CLI queries"
```

---

### Task 4: `workforce list` command

**Files:**
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/ListCommand.swift`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Workforce.swift`

**Step 1: Create ListCommand.swift**

```swift
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
```

**Step 2: Register in Workforce.swift**

Add `ListCommand.self` to the subcommands array in `Workforce.swift:10-23`.

**Step 3: Build and test**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Then: `.build/debug/workforce list`
Expected: Either table output or "No active sessions."

Test with `--json`: `.build/debug/workforce list --json`
Expected: JSON array

**Step 4: Commit**

```bash
git add WorkforceKit/Sources/WorkforceCLI/Commands/ListCommand.swift WorkforceKit/Sources/WorkforceCLI/Workforce.swift
git commit -m "feat: add workforce list command"
```

---

### Task 5: `workforce attach` command

**Files:**
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/AttachCommand.swift`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Workforce.swift`

**Step 1: Create AttachCommand.swift**

```swift
import ArgumentParser
import Foundation
import WorkforceKit

struct AttachCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach to an agent's tmux session"
    )

    @Argument(help: "Session name or partial ID (e.g. 'workforce-a1b2c3' or 'a1b2c3')")
    var target: String

    func run() throws {
        let agents = APIClient.fetchAgents() ?? TmuxClient.discoverAgents()

        let matches = agents.filter { agent in
            agent.sessionId == target
            || agent.sessionId == "workforce-\(target)"
            || agent.tmuxSession == target
            || agent.sessionId.hasSuffix(target)
        }

        guard !matches.isEmpty else {
            throw ValidationError("No session matching '\(target)'. Run 'workforce list' to see available sessions.")
        }

        guard matches.count == 1 else {
            var message = "Multiple sessions match '\(target)':\n"
            for agent in matches {
                message += "  \(agent.sessionId)\n"
            }
            message += "Please be more specific."
            throw ValidationError(message)
        }

        let agent = matches[0]
        let tmuxSession = agent.tmuxSession ?? agent.sessionId

        try TmuxClient.attach(session: tmuxSession)
    }
}
```

**Step 2: Register in Workforce.swift**

Add `AttachCommand.self` to the subcommands array.

**Step 3: Build and test**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Then (with a running session): `.build/debug/workforce attach <session-name>`
Expected: Attaches to tmux session

Test with bad target: `.build/debug/workforce attach nonexistent`
Expected: Error message with suggestion

**Step 4: Commit**

```bash
git add WorkforceKit/Sources/WorkforceCLI/Commands/AttachCommand.swift WorkforceKit/Sources/WorkforceCLI/Workforce.swift
git commit -m "feat: add workforce attach command"
```

---

### Task 6: `workforce tui` command

**Files:**
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/TUICommand.swift`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Workforce.swift`

**Step 1: Create TUICommand.swift**

Uses Darwin.ncurses for an interactive session picker.

```swift
import ArgumentParser
import Foundation
import WorkforceKit
import Darwin.ncurses

struct TUICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Interactive session picker"
    )

    func run() throws {
        var agents = fetchAgents()
        if agents.isEmpty {
            print("No active sessions.")
            return
        }

        // Init ncurses
        setlocale(LC_ALL, "")
        initscr()
        defer { endwin() }
        cbreak()
        noecho()
        curs_set(0)
        keypad(stdscr, true)
        start_color()
        timeout(3000) // 3 second refresh

        // Define color pairs
        init_pair(1, Int16(COLOR_GREEN), Int16(COLOR_BLACK))   // active
        init_pair(2, Int16(COLOR_CYAN), Int16(COLOR_BLACK))    // waiting
        init_pair(3, Int16(COLOR_WHITE), Int16(COLOR_BLACK))   // idle
        init_pair(4, Int16(COLOR_RED), Int16(COLOR_BLACK))     // stopped
        init_pair(5, Int16(COLOR_BLACK), Int16(COLOR_WHITE))   // selected row

        var selectedIndex = 0
        var shouldQuit = false

        while !shouldQuit {
            erase()

            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let maxY = Int(getmaxy(stdscr))
            let maxX = Int(getmaxx(stdscr))

            // Header
            attron(A_BOLD)
            mvaddstr(0, 1, " Workforce Sessions (\(agents.count))")
            attroff(A_BOLD)
            mvhline(1, 0, Int32(Character("-").asciiValue!), Int32(maxX))

            // Column headers
            let headerY: Int32 = 2
            attron(A_BOLD)
            mvaddstr(headerY, 1, "  SESSION              AGENT      STATUS     CWD")
            attroff(A_BOLD)

            // Rows
            let startY: Int32 = 3
            let maxRows = maxY - 5 // leave room for footer

            for (i, agent) in agents.enumerated() {
                guard i < maxRows else { break }
                let y = startY + Int32(i)
                let isSelected = i == selectedIndex

                if isSelected {
                    attron(COLOR_PAIR(5))
                }

                // Status dot
                let (dot, colorPair) = statusIndicator(agent.status)
                if !isSelected {
                    attron(COLOR_PAIR(Int32(colorPair)))
                }
                mvaddstr(y, 1, dot)
                if !isSelected {
                    attroff(COLOR_PAIR(Int32(colorPair)))
                }

                let shortCwd = agent.cwd.hasPrefix(home)
                    ? "~" + agent.cwd.dropFirst(home.count)
                    : agent.cwd
                let truncCwd = String(shortCwd.prefix(maxX - 50))

                let row = String(format: " %-20s %-10s %-10s %@",
                    (agent.sessionId as NSString).utf8String!,
                    (agent.agentType as NSString).utf8String!,
                    (agent.status.rawValue as NSString).utf8String!,
                    truncCwd)
                mvaddstr(y, 2, row)

                if isSelected {
                    attroff(COLOR_PAIR(5))
                }
            }

            // Footer
            let footerY = Int32(maxY - 1)
            mvhline(footerY - 1, 0, Int32(Character("-").asciiValue!), Int32(maxX))
            mvaddstr(footerY, 1, " ↑↓ navigate  ⏎ attach  q quit  r refresh")

            refresh()

            let ch = getch()
            switch ch {
            case Int32(Character("q").asciiValue!), Int32(Character("Q").asciiValue!):
                shouldQuit = true

            case Int32(Character("r").asciiValue!), Int32(Character("R").asciiValue!):
                agents = fetchAgents()
                if selectedIndex >= agents.count {
                    selectedIndex = max(0, agents.count - 1)
                }

            case KEY_UP:
                if selectedIndex > 0 { selectedIndex -= 1 }

            case KEY_DOWN:
                if selectedIndex < agents.count - 1 { selectedIndex += 1 }

            case 10, KEY_ENTER: // Enter
                guard !agents.isEmpty else { break }
                let agent = agents[selectedIndex]
                let tmuxSession = agent.tmuxSession ?? agent.sessionId
                endwin()
                try TmuxClient.attach(session: tmuxSession)
                return

            case ERR: // timeout — auto-refresh
                agents = fetchAgents()
                if agents.isEmpty {
                    endwin()
                    print("No active sessions.")
                    return
                }
                if selectedIndex >= agents.count {
                    selectedIndex = max(0, agents.count - 1)
                }

            default:
                break
            }
        }
    }

    private func fetchAgents() -> [Agent] {
        APIClient.fetchAgents() ?? TmuxClient.discoverAgents()
    }

    private func statusIndicator(_ status: AgentStatus) -> (String, Int) {
        switch status {
        case .active:               return ("●", 1)
        case .waitingForInput:      return ("◉", 2)
        case .waitingForPermission: return ("◉", 2)
        case .idle:                 return ("○", 3)
        case .stopped:              return ("○", 4)
        }
    }
}
```

**Step 2: Add ncurses linking to Package.swift**

ncurses is available as a system library on macOS. Add a system library target or use linker flags. The simplest approach:

In `WorkforceKit/Package.swift`, add a linker setting to the `WorkforceCLI` target:

```swift
.executableTarget(
    name: "WorkforceCLI",
    dependencies: [
        "WorkforceKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ],
    linkerSettings: [
        .linkedLibrary("ncurses"),
    ]
)
```

**Step 3: Register in Workforce.swift**

Add `TUICommand.self` to the subcommands array.

**Step 4: Build and test**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Then: `.build/debug/workforce tui`
Expected: Interactive ncurses TUI appears, arrow keys work, q quits

**Step 5: Commit**

```bash
git add WorkforceKit/Sources/WorkforceCLI/Commands/TUICommand.swift WorkforceKit/Package.swift WorkforceKit/Sources/WorkforceCLI/Workforce.swift
git commit -m "feat: add workforce tui command with ncurses session picker"
```

---

### Task 7: Cleanup HTTP server on app quit

**Files:**
- Modify: `Workforce/Workforce/WorkforceApp.swift`

**Step 1: Ensure port file is cleaned up**

The `HTTPServer.stop()` method already removes the port file. Make sure it's called when the app terminates. Add an `onDisappear` or `NSApplication` termination observer in `WorkforceApp`.

The simplest approach: add to MainWindowView or use `@Environment(\.scenePhase)` — but since this is a macOS app, use `NSApplication.willTerminateNotification`:

```swift
// In WorkforceApp.init(), after starting HTTP server:
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
    http.stop()
}
```

**Step 2: Build and verify**

Build, run app, verify port file exists. Quit app, verify port file is removed.

**Step 3: Commit**

```bash
git add Workforce/Workforce/WorkforceApp.swift
git commit -m "fix: clean up HTTP server port file on app quit"
```

---

### Task 8: Final integration test

**Step 1: Build everything**

Build CLI: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Build app: Open Xcode, build and run.

**Step 2: Test full flow**

1. Launch the app
2. Spawn an agent from the app (or run `workforce run`)
3. In another terminal: `workforce list` — verify output shows the session with correct columns
4. `workforce list --json` — verify JSON output
5. `workforce attach <session-name>` — verify it attaches
6. `workforce tui` — verify interactive picker, navigate, attach

**Step 3: Test tmux fallback**

1. Quit the app
2. `workforce list` — should still show sessions (from tmux)
3. `workforce attach <session>` — should still work
4. `workforce tui` — should still work

**Step 4: Commit any fixes, then done**
