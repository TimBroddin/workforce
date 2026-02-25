# Remote SSH Agent Support — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Connect to remote machines over SSH and view/interact with/spawn agents running there, all from within the Workforce macOS app.

**Architecture:** SSH tunnel forwards the remote Workforce HTTP API to a local port. App polls the tunnel endpoint for agent state. Terminal interaction forks `ssh -t host tmux attach` through the existing PTY/xterm.js setup. A `RemoteHostManager` owns tunnel lifecycle and remote agent state, separate from the local `AgentStore`.

**Tech Stack:** Swift, SwiftUI, Foundation.Process (for SSH), Network.framework (existing HTTP server), xterm.js (existing terminal)

---

### Task 1: Add `host` field to Agent model

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceKit/Models/Agent.swift:11-105`

**Step 1: Add the host property**

Add `host: String?` to the `Agent` struct. It must be `Codable` (already is via optional String), added to the init, and default to `nil` so all existing code compiles without changes.

```swift
// In Agent struct, after line 22 (tmuxSession):
public let host: String?
```

Update the `init` signature (line 56-77) to include `host: String? = nil` and assign it in the body.

Update `displayTitle` — if `host` is non-nil, the path abbreviation should not try to resolve `~` (it's a remote path).

**Step 2: Verify it compiles**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add WorkforceKit/Sources/WorkforceKit/Models/Agent.swift
git commit -m "feat: add host field to Agent model for remote support"
```

---

### Task 2: Create RemoteHost model

**Files:**
- Create: `Workforce/Workforce/Services/RemoteHost.swift`

**Step 1: Write the model**

```swift
import Foundation

enum ConnectionStatus: Equatable {
    case disabled
    case connecting
    case connected
    case error(String)

    var label: String {
        switch self {
        case .disabled: "Disabled"
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .error(let msg): "Error: \(msg)"
        }
    }
}

struct RemoteHost: Codable, Identifiable {
    let id: UUID
    var label: String
    var sshDestination: String
    var sshPort: Int
    var sshKeyPath: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        label: String,
        sshDestination: String,
        sshPort: Int = 22,
        sshKeyPath: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.sshDestination = sshDestination
        self.sshPort = sshPort
        self.sshKeyPath = sshKeyPath
        self.isEnabled = isEnabled
    }

    /// Build the base SSH command arguments for this host.
    var sshBaseArgs: [String] {
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        if sshPort != 22 {
            args += ["-p", "\(sshPort)"]
        }
        if let key = sshKeyPath {
            args += ["-i", key]
        }
        args.append(sshDestination)
        return args
    }
}
```

**Step 2: Verify it compiles**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Workforce/Workforce/Services/RemoteHost.swift
git commit -m "feat: add RemoteHost model with SSH config"
```

---

### Task 3: Create RemoteHostManager — persistence and SSH tunnel lifecycle

**Files:**
- Create: `Workforce/Workforce/Services/RemoteHostManager.swift`

**Step 1: Write RemoteHostManager**

This is the core service. It manages:
- Persisting `[RemoteHost]` to disk (same pattern as AgentStore)
- SSH tunnel lifecycle per host (Process + port forwarding)
- Polling remote agents through the tunnel
- Reconnection with exponential backoff

```swift
import Foundation
import Observation

@Observable
final class RemoteHostManager {
    var hosts: [RemoteHost] = []
    var connections: [UUID: RemoteConnection] = [:]

    struct RemoteConnection {
        var status: ConnectionStatus = .disabled
        var sshProcess: Process?
        var localPort: UInt16 = 0
        var agents: [Agent] = []
        var lastError: String?
        var retryCount: Int = 0
    }

    // All remote agents across all hosts, with host field set
    var allRemoteAgents: [Agent] {
        connections.values.flatMap(\.agents)
    }

    private static let storePath: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Workforce", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("remote-hosts.json")
    }()

    private let sshPath: String = {
        ["/usr/bin/ssh"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/ssh"
    }()

    // MARK: - Persistence

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(hosts) else { return }
        try? data.write(to: Self.storePath, options: .atomic)
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.storePath) else { return }
        guard let saved = try? JSONDecoder().decode([RemoteHost].self, from: data) else { return }
        hosts = saved
    }

    func addHost(_ host: RemoteHost) {
        hosts.append(host)
        save()
        if host.isEnabled {
            connect(host)
        }
    }

    func removeHost(_ id: UUID) {
        disconnect(id)
        hosts.removeAll { $0.id == id }
        connections.removeValue(forKey: id)
        save()
    }

    func updateHost(_ host: RemoteHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let wasEnabled = hosts[index].isEnabled
        hosts[index] = host
        save()

        if host.isEnabled && !wasEnabled {
            connect(host)
        } else if !host.isEnabled && wasEnabled {
            disconnect(host.id)
        } else if host.isEnabled {
            // Config changed — reconnect
            disconnect(host.id)
            connect(host)
        }
    }

    // MARK: - Connection lifecycle

    func connectAll() {
        for host in hosts where host.isEnabled {
            connect(host)
        }
    }

    func disconnectAll() {
        for host in hosts {
            disconnect(host.id)
        }
    }

    func connect(_ host: RemoteHost) {
        var conn = connections[host.id] ?? RemoteConnection()
        conn.status = .connecting
        connections[host.id] = conn

        // Step 1: discover remote port
        discoverRemotePort(host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let remotePort):
                self.openTunnel(host: host, remotePort: remotePort)
            case .failure(let error):
                var conn = self.connections[host.id] ?? RemoteConnection()
                conn.status = .error(error.localizedDescription)
                conn.lastError = error.localizedDescription
                self.connections[host.id] = conn
                self.scheduleRetry(host: host)
            }
        }
    }

    func disconnect(_ hostId: UUID) {
        guard var conn = connections[hostId] else { return }
        if let process = conn.sshProcess, process.isRunning {
            process.terminate()
        }
        conn.sshProcess = nil
        conn.status = .disabled
        conn.agents = []
        conn.retryCount = 0
        connections[hostId] = conn
    }

    func retryConnection(_ hostId: UUID) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        var conn = connections[hostId] ?? RemoteConnection()
        conn.retryCount = 0
        connections[hostId] = conn
        connect(host)
    }

    // MARK: - SSH operations

    private func discoverRemotePort(host: RemoteHost, completion: @escaping (Result<UInt16, Error>) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = host.sshBaseArgs + ["cat /tmp/workforce-*.port 2>/dev/null || echo NOPORT"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            completion(.failure(error))
            return
        }

        DispatchQueue.global().async {
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if process.terminationStatus != 0 {
                    completion(.failure(NSError(domain: "SSH", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "SSH connection failed (exit \(process.terminationStatus))"])))
                } else if output == "NOPORT" || output.isEmpty {
                    completion(.failure(NSError(domain: "SSH", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Workforce not running on remote (no port file)"])))
                } else if let port = UInt16(output) {
                    completion(.success(port))
                } else {
                    completion(.failure(NSError(domain: "SSH", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid port file contents: \(output)"])))
                }
            }
        }
    }

    private func openTunnel(host: RemoteHost, remotePort: UInt16) {
        // Find a free local port
        let localPort = findFreePort()
        guard localPort > 0 else {
            var conn = connections[host.id] ?? RemoteConnection()
            conn.status = .error("Could not find free local port")
            connections[host.id] = conn
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = host.sshBaseArgs.dropLast().map(String.init) + [
            "-N",
            "-L", "\(localPort):localhost:\(remotePort)",
            host.sshDestination
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                guard var conn = self.connections[host.id],
                      conn.sshProcess === proc else { return }
                conn.sshProcess = nil
                conn.status = .error("SSH tunnel closed (exit \(proc.terminationStatus))")
                self.connections[host.id] = conn
                self.scheduleRetry(host: host)
            }
        }

        do {
            try process.run()
            var conn = connections[host.id] ?? RemoteConnection()
            conn.sshProcess = process
            conn.localPort = localPort
            conn.status = .connected
            conn.retryCount = 0
            connections[host.id] = conn

            // Start polling after a brief delay for the tunnel to establish
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.pollAgents(hostId: host.id)
            }
        } catch {
            var conn = connections[host.id] ?? RemoteConnection()
            conn.status = .error("Failed to start SSH: \(error.localizedDescription)")
            connections[host.id] = conn
            scheduleRetry(host: host)
        }
    }

    // MARK: - Polling

    func pollAgents(hostId: UUID) {
        guard let conn = connections[hostId], conn.status == .connected, conn.localPort > 0 else { return }
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        guard let url = URL(string: "http://localhost:\(conn.localPort)/api/agents") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard var conn = self.connections[hostId] else { return }

                if let data, error == nil,
                   let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if var agents = try? decoder.decode([Agent].self, from: data) {
                        // Tag each agent with the host
                        agents = agents.map { agent in
                            Agent(
                                sessionId: agent.sessionId,
                                name: agent.name,
                                avatarSeed: agent.avatarSeed,
                                cwd: agent.cwd,
                                agentType: agent.agentType,
                                model: agent.model,
                                tmuxSession: agent.tmuxSession,
                                startedAt: agent.startedAt,
                                lastActivityAt: agent.lastActivityAt,
                                status: agent.status,
                                currentToolName: agent.currentToolName,
                                lastNotificationType: agent.lastNotificationType,
                                subagentCount: agent.subagentCount,
                                paneTitle: agent.paneTitle,
                                transcriptPath: agent.transcriptPath,
                                notificationMessage: agent.notificationMessage,
                                totalInputTokens: agent.totalInputTokens,
                                totalOutputTokens: agent.totalOutputTokens,
                                totalCacheCreationTokens: agent.totalCacheCreationTokens,
                                totalCacheReadTokens: agent.totalCacheReadTokens,
                                host: host.sshDestination
                            )
                        }
                        conn.agents = agents
                        conn.status = .connected
                    }
                }
                self.connections[hostId] = conn
            }
        }.resume()
    }

    // MARK: - Retry with exponential backoff

    private func scheduleRetry(host: RemoteHost) {
        guard host.isEnabled else { return }
        guard var conn = connections[host.id] else { return }
        conn.retryCount += 1
        connections[host.id] = conn

        let delays = [5.0, 10.0, 30.0, 60.0]
        let delay = delays[min(conn.retryCount - 1, delays.count - 1)]

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let current = self.hosts.first(where: { $0.id == host.id }),
                  current.isEnabled else { return }
            self.connect(current)
        }
    }

    // MARK: - Spawn remote agent

    func spawnAgent(host: RemoteHost, cwd: String, agentType: String = "claude", completion: @escaping (Result<String, Error>) -> Void) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let sessionName = "workforce-\(timestamp)"
        let shell = "zsh"

        let remoteCommand = "tmux new-session -d -s \(sessionName) -c \(cwd) -e WORKFORCE_SESSION=\(sessionName) -- \(shell) -lc \(agentType)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = host.sshBaseArgs + [remoteCommand]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            completion(.failure(error))
            return
        }

        DispatchQueue.global().async {
            process.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    completion(.success(sessionName))
                } else {
                    completion(.failure(NSError(domain: "SSH", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: errMsg.isEmpty ? "Remote command failed" : errMsg])))
                }
            }
        }
    }

    // MARK: - Utilities

    private func findFreePort() -> UInt16 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 0 }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = 0 // Let OS pick

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 0 }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &len)
            }
        }
        guard nameResult == 0 else { return 0 }

        return UInt16(bigEndian: addr.sin_port)
    }
}
```

**Step 2: Verify it compiles**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Workforce/Workforce/Services/RemoteHostManager.swift
git commit -m "feat: add RemoteHostManager with SSH tunnel lifecycle and agent polling"
```

---

### Task 4: Wire RemoteHostManager into the app

**Files:**
- Modify: `Workforce/Workforce/WorkforceApp.swift:9-68`

**Step 1: Add RemoteHostManager as app state**

In `WorkforceApp`, add a `@State private var remoteHostManager = RemoteHostManager()` alongside the existing `agentStore`. In `init()`, call `remoteHostManager.load()` and `remoteHostManager.connectAll()`. In the `willTerminateNotification` handler, call `remoteHostManager.disconnectAll()`.

Pass `remoteHostManager` to `MainWindowView` and `SettingsView`.

**Step 2: Verify it compiles**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (may need stub parameters in views first — accept them but don't use yet)

**Step 3: Commit**

```bash
git add Workforce/Workforce/WorkforceApp.swift
git commit -m "feat: wire RemoteHostManager into app lifecycle"
```

---

### Task 5: Add Remote Hosts settings tab

**Files:**
- Modify: `Workforce/Workforce/Views/SettingsView.swift:1-18` (add tab)
- Add new view in same file (or new file if it gets large)

**Step 1: Create RemoteHostsSettingsView**

Add a new view struct at the bottom of `SettingsView.swift` (or create `Workforce/Workforce/Views/RemoteHostsSettingsView.swift`). It displays:

- A List of configured hosts, each row showing: label, sshDestination, connection status dot (green/red/gray), enable/disable toggle
- "Add Host" button opens a sheet with fields: label, SSH destination, port (default 22), SSH key path (optional file picker)
- Edit/delete via context menu or swipe
- "Test Connection" button per host that runs the port discovery SSH command and shows result

Add a `RemoteHosts` tab to the `TabView` in `SettingsView`:

```swift
RemoteHostsSettingsView(manager: remoteHostManager)
    .tabItem {
        Label("Remote Hosts", systemImage: "network")
    }
```

**Step 2: Verify it compiles and the tab appears**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Workforce/Workforce/Views/SettingsView.swift
# or: git add Workforce/Workforce/Views/RemoteHostsSettingsView.swift
git commit -m "feat: add Remote Hosts settings tab"
```

---

### Task 6: Add polling timer for remote agents

**Files:**
- Modify: `Workforce/Workforce/Views/MainWindowView.swift`

**Step 1: Add polling task**

In `MainWindowView`, accept `remoteHostManager: RemoteHostManager` as a parameter. Add a `.task` block that polls all connected hosts every 5 seconds:

```swift
.task {
    while !Task.isCancelled {
        for host in remoteHostManager.hosts where host.isEnabled {
            remoteHostManager.pollAgents(hostId: host.id)
        }
        try? await Task.sleep(for: .seconds(5))
    }
}
```

**Step 2: Verify it compiles**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Workforce/Workforce/Views/MainWindowView.swift
git commit -m "feat: add 5-second polling timer for remote agents"
```

---

### Task 7: Restructure sidebar to group by host

**Files:**
- Modify: `Workforce/Workforce/Views/MainWindowView.swift:24-372` (sidebar section)

**Step 1: Add host sections to sidebar**

Restructure the sidebar to show sections per host:

1. **"Local" section** — uses existing `sidebarCwds` and `agents(for:)` logic, unchanged
2. **Per remote host sections** — header shows `host.label` + connection status badge. Below it, folders and agents from `remoteHostManager.connections[host.id]?.agents`, grouped by cwd the same way local agents are

The section header for remote hosts shows:
- Host label (e.g., "Home Mac")
- Connection status dot (green = connected, red = error, gray = disabled)
- If error: a retry button
- "+" menu for spawning remote agents (same as local but calls `remoteHostManager.spawnAgent`)

Collapsing works per-host using the existing `collapsedCwds` set (prefix remote cwds with host id to namespace them).

**Step 2: Verify it compiles and renders**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Workforce/Workforce/Views/MainWindowView.swift
git commit -m "feat: restructure sidebar with host sections for local and remote agents"
```

---

### Task 8: Remote terminal support via SSH

**Files:**
- Modify: `Workforce/Workforce/Views/TerminalView.swift:86-194` (TerminalRepresentable + Coordinator)

**Step 1: Add SSH-aware startPTY**

Modify `TerminalRepresentable` to accept an optional `host: String?` and optional `sshPort: Int?` alongside `sessionName`. Rename `startPTY(sessionName:)` to `startPTY(sessionName:host:sshPort:)`.

In `startPTY`, branch on `host`:

```swift
func startPTY(sessionName: String, host: String? = nil, sshPort: Int? = nil) {
    let tmuxPath = findExecutable("tmux") ?? "/opt/homebrew/bin/tmux"

    let args: [String]
    let execPath: String

    if let host {
        // Remote: ssh -t [-p port] user@host tmux -u attach -t session
        let sshPath = "/usr/bin/ssh"
        var sshArgs = [sshPath, "-t"]
        if let port = sshPort, port != 22 {
            sshArgs += ["-p", "\(port)"]
        }
        sshArgs += [host, tmuxPath, "-u", "attach", "-t", sessionName]
        args = sshArgs
        execPath = sshPath
    } else {
        // Local: tmux -u attach -t session
        args = [tmuxPath, "-u", "attach", "-t", sessionName]
        execPath = tmuxPath
    }

    // ... rest of forkpty logic uses execPath and args
}
```

Update `makeNSView` to pass `host` through to `startPTY`.

**Step 2: Update callers**

In `MainWindowView`, when showing the terminal pane for a remote agent, pass the agent's `host` to `TerminalRepresentable`.

**Step 3: Verify it compiles**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Workforce/Workforce/Views/TerminalView.swift Workforce/Workforce/Views/MainWindowView.swift
git commit -m "feat: support SSH terminal attachment for remote agents"
```

---

### Task 9: Update footer and context menus for remote agents

**Files:**
- Modify: `Workforce/Workforce/Views/MainWindowView.swift:530-558` (footer)
- Modify: `Workforce/Workforce/Views/MainWindowView.swift:339-363` (context menu)

**Step 1: Update footer**

Include remote agents in the total count and cost:

```swift
let localCount = store.agents.count
let remoteCount = remoteHostManager.allRemoteAgents.count
let total = localCount + remoteCount
Text("\(total) agent\(total == 1 ? "" : "s")")
```

Add remote agent costs to the total cost calculation.

**Step 2: Update context menus**

For remote agents, remove "Open in Finder" and change "Open in Terminal" to open `ssh -t host tmux attach` in the preferred terminal app (update `AppLauncher` if needed). Remove "Copy tmux Command" and replace with "Copy SSH Command" that copies `ssh -t user@host tmux -u attach -t <session>`.

**Step 3: Verify it compiles**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Workforce/Workforce/Views/MainWindowView.swift
git commit -m "feat: update footer counts and context menus for remote agents"
```

---

### Task 10: Handle agent selection across local and remote

**Files:**
- Modify: `Workforce/Workforce/Views/MainWindowView.swift`

**Step 1: Support selecting remote agents**

Currently `selectedAgentId` looks up agents in `store.agents[id]`. Remote agents live in `remoteHostManager`. Update `selectedAgent` computed property to check both:

```swift
private var selectedAgent: Agent? {
    if let selectedAgentId {
        if let agent = store.agents[selectedAgentId] {
            return agent
        }
        // Check remote agents
        for conn in remoteHostManager.connections.values {
            if let agent = conn.agents.first(where: { $0.sessionId == selectedAgentId }) {
                return agent
            }
        }
    }
    return store.sortedAgents.first
}
```

Also update `selectedTmuxSession` and `isSelected` to work with remote agents.

**Step 2: Verify it compiles**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Workforce/Workforce/Views/MainWindowView.swift
git commit -m "feat: support selecting and displaying remote agents"
```

---

### Task 11: End-to-end manual test

**Step 1: Build and run the app**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 2: Manual test checklist**

- [ ] Open Settings → Remote Hosts tab appears
- [ ] Add a remote host (use a machine you can SSH to with key auth)
- [ ] Connection status shows "Connecting..." then "Connected" (or appropriate error)
- [ ] Remote agents appear in sidebar under the host label
- [ ] Clicking a remote agent shows its terminal via SSH
- [ ] Spawning a new agent on the remote host works (+ menu)
- [ ] Disconnecting/disabling a host removes its agents from sidebar
- [ ] Killing the SSH tunnel triggers reconnection
- [ ] Footer shows correct total agent count including remote
- [ ] Context menu for remote agents shows "Copy SSH Command" instead of "Copy tmux Command"

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: address issues found during end-to-end testing"
```
