# Embedded Terminal Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an embedded SwiftTerm terminal to the Workforce app, with a main window featuring tabs per working directory, an agent sidebar, and a terminal pane that attaches to tmux sessions created by `workforce run`.

**Architecture:** `workforce run` wraps `claude` in a named tmux session. The SessionStart hook detects the tmux session name and passes it to the app. The app opens a main window (replacing the popover) with a tab bar grouped by cwd, a sidebar listing agents, and SwiftTerm attached to the selected agent's tmux session.

**Tech Stack:** Swift 6, SwiftUI, AppKit (NSViewRepresentable), SwiftTerm (SPM), tmux, ArgumentParser

---

## Task 1: Add `tmuxSession` field to models (bd-os1.3 partial)

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift`
- Modify: `WorkforceKit/Sources/WorkforceKit/Models/Agent.swift`
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Models/SocketMessage.swift`
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Models/Agent.swift`

**Step 1: Add `tmuxSession` to WorkforceKit SocketMessage**

In `WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift`, add the field:

```swift
// After the line: public var agentType: String?
public var tmuxSession: String?
```

And add it to the init:

```swift
public init(
    type: SocketMessageType,
    sessionId: String,
    cwd: String,
    timestamp: Date = Date(),
    name: String? = nil,
    avatarSeed: String? = nil,
    hostApp: HostApp? = nil,
    hostBundleId: String? = nil,
    hostPid: Int32? = nil,
    model: String? = nil,
    status: AgentStatus? = nil,
    toolName: String? = nil,
    notificationType: String? = nil,
    agentType: String? = nil,
    tmuxSession: String? = nil
) {
    // ... existing assignments ...
    self.tmuxSession = tmuxSession
}
```

**Step 2: Add `tmuxSession` to WorkforceKit Agent**

In `WorkforceKit/Sources/WorkforceKit/Models/Agent.swift`, add:

```swift
// After: public let model: String?
public let tmuxSession: String?
```

And add to init parameter list:

```swift
public init(
    sessionId: String,
    name: String,
    avatarSeed: String,
    cwd: String,
    hostApp: HostApp,
    hostBundleId: String?,
    hostPid: Int32?,
    model: String? = nil,
    tmuxSession: String? = nil,
    startedAt: Date = Date(),
    // ... rest stays same
) {
    // ... existing assignments ...
    self.tmuxSession = tmuxSession
}
```

**Step 3: Mirror changes in app-side models**

Apply the exact same changes to:
- `Workforce for Claude Code/Workforce for Claude Code/Models/SocketMessage.swift`
- `Workforce for Claude Code/Workforce for Claude Code/Models/Agent.swift`

**Step 4: Update AgentStore to pass tmuxSession**

In `Workforce for Claude Code/Workforce for Claude Code/Services/AgentStore.swift`, update the `handleMessage` `.register` case:

```swift
case .register:
    let agent = Agent(
        sessionId: message.sessionId,
        name: message.name ?? NameGenerator.generate(from: message.sessionId),
        avatarSeed: message.avatarSeed ?? message.sessionId,
        cwd: message.cwd,
        hostApp: message.hostApp ?? .unknown,
        hostBundleId: message.hostBundleId,
        hostPid: message.hostPid,
        model: message.model,
        tmuxSession: message.tmuxSession,
        status: message.status ?? .active
    )
    agents[message.sessionId] = agent
```

And the same in `registerMinimal`:

```swift
private func registerMinimal(from message: SocketMessage) {
    let agent = Agent(
        sessionId: message.sessionId,
        name: NameGenerator.generate(from: message.sessionId),
        avatarSeed: message.sessionId,
        cwd: message.cwd,
        hostApp: message.hostApp ?? .unknown,
        hostBundleId: message.hostBundleId,
        hostPid: message.hostPid,
        tmuxSession: message.tmuxSession,
        status: message.status ?? .active,
        currentToolName: message.toolName
    )
    agents[message.sessionId] = agent
}
```

**Step 5: Build WorkforceKit to verify**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift \
        WorkforceKit/Sources/WorkforceKit/Models/Agent.swift \
        "Workforce for Claude Code/Workforce for Claude Code/Models/SocketMessage.swift" \
        "Workforce for Claude Code/Workforce for Claude Code/Models/Agent.swift" \
        "Workforce for Claude Code/Workforce for Claude Code/Services/AgentStore.swift"
git commit -m "feat: add tmuxSession field to Agent and SocketMessage models"
```

---

## Task 2: Detect tmux session in SessionStart hook (bd-os1.3)

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/SessionStartCommand.swift`

**Step 1: Add tmux detection to SessionStartCommand**

Replace the `run()` method:

```swift
func run() throws {
    let data = try readStdin()
    let event = try JSONDecoder().decode(SessionStartEvent.self, from: data)
    let host = HostDetection.detect()

    // Detect tmux session name from environment
    let tmuxSession = detectTmuxSession()

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
        tmuxSession: tmuxSession
    )
    SocketClient.send(message)
}

/// Detect the current tmux session name, if running inside tmux.
/// The TMUX env var format is: /path/to/socket,pid,session-index
/// We use `tmux display-message` to get the actual session name.
private func detectTmuxSession() -> String? {
    guard ProcessInfo.processInfo.environment["TMUX"] != nil else {
        return nil
    }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["tmux", "display-message", "-p", "#{session_name}"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    } catch {
        return nil
    }
}
```

**Step 2: Build to verify**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add WorkforceKit/Sources/WorkforceCLI/Commands/SessionStartCommand.swift
git commit -m "feat: detect tmux session name in SessionStart hook"
```

---

## Task 3: Add `workforce run` CLI command (bd-os1.2)

**Files:**
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/RunCommand.swift`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Workforce.swift`

**Step 1: Create RunCommand.swift**

```swift
import ArgumentParser
import Foundation

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run Claude Code inside a tmux session",
        discussion: """
        Wraps `claude` in a named tmux session so the Workforce app can attach to it.
        Everything after -- is passed to claude.

        Examples:
          workforce run
          workforce run -- --model opus
          workforce run -- "fix the login bug"
        """
    )

    @Argument(parsing: .allUnrecognized)
    var claudeArgs: [String] = []

    func run() throws {
        // Check tmux is available
        let whichTmux = Process()
        whichTmux.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        whichTmux.arguments = ["which", "tmux"]
        whichTmux.standardOutput = FileHandle.nullDevice
        whichTmux.standardError = FileHandle.nullDevice
        try whichTmux.run()
        whichTmux.waitUntilExit()
        guard whichTmux.terminationStatus == 0 else {
            throw ValidationError(
                "tmux not found. Install with: brew install tmux"
            )
        }

        // Check claude is available
        let whichClaude = Process()
        whichClaude.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        whichClaude.arguments = ["which", "claude"]
        whichClaude.standardOutput = FileHandle.nullDevice
        whichClaude.standardError = FileHandle.nullDevice
        try whichClaude.run()
        whichClaude.waitUntilExit()
        guard whichClaude.terminationStatus == 0 else {
            throw ValidationError(
                "claude not found. Install Claude Code first: https://docs.anthropic.com/en/docs/claude-code"
            )
        }

        // Generate session name
        let hexBytes = (0..<3).map { _ in UInt8.random(in: 0...255) }
        let hex = hexBytes.map { String(format: "%02x", $0) }.joined()
        let sessionName = "workforce-\(hex)"

        // Build tmux command: tmux new-session -s <name> -- claude [args...]
        let tmux = Process()
        tmux.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var tmuxArgs = ["tmux", "new-session", "-s", sessionName, "--", "claude"]
        tmuxArgs.append(contentsOf: claudeArgs)
        tmux.arguments = tmuxArgs
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
}
```

**Step 2: Register RunCommand in Workforce.swift**

In `WorkforceKit/Sources/WorkforceCLI/Workforce.swift`, add `RunCommand.self` to subcommands:

```swift
@main
struct Workforce: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workforce",
        abstract: "CLI companion for Workforce for Claude Code",
        subcommands: [
            RunCommand.self,
            SessionStartCommand.self,
            // ... rest stays same
        ]
    )
}
```

**Step 3: Build to verify**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Expected: BUILD SUCCEEDED

**Step 4: Verify help output**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && .build/debug/workforce run --help`
Expected: Shows usage info for `workforce run`

**Step 5: Commit**

```bash
git add WorkforceKit/Sources/WorkforceCLI/Commands/RunCommand.swift \
        WorkforceKit/Sources/WorkforceCLI/Workforce.swift
git commit -m "feat: add workforce run command to wrap claude in tmux"
```

---

## Task 4: Add SwiftTerm SPM dependency to Xcode project (bd-os1.1)

**Files:**
- Modify: `Workforce for Claude Code/Workforce for Claude Code.xcodeproj/project.pbxproj`

**Step 1: Add SwiftTerm package via Xcode**

This must be done via Xcode UI or by editing project.pbxproj. The safest approach is `xcodebuild` won't help here — use the Xcode GUI:

1. Open `Workforce for Claude Code.xcodeproj` in Xcode
2. Select the project in the navigator
3. Go to "Package Dependencies" tab
4. Click "+" and enter: `https://github.com/migueldeicaza/SwiftTerm.git`
5. Set version rule to "Up to Next Major" from `1.10.0`
6. Add `SwiftTerm` library to the "Workforce for Claude Code" target

Alternatively, edit the pbxproj programmatically by adding the required XCRemoteSwiftPackageReference and XCSwiftPackageProductDependency sections. This is fragile — prefer Xcode UI.

**Step 2: Verify build**

Build the project in Xcode (Cmd+B) to verify SwiftTerm resolves and compiles.

**Step 3: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code.xcodeproj/project.pbxproj"
git commit -m "feat: add SwiftTerm SPM dependency"
```

---

## Task 5: Replace menu bar popover with main window (bd-os1.4)

**Files:**
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Workforce_for_Claude_CodeApp.swift`
- Create: `Workforce for Claude Code/Workforce for Claude Code/Views/MainWindowView.swift`

**Step 1: Create MainWindowView placeholder**

Create `Workforce for Claude Code/Workforce for Claude Code/Views/MainWindowView.swift`:

```swift
import SwiftUI

struct MainWindowView: View {
    let store: AgentStore

    var body: some View {
        Text("Main window — will add tabs + sidebar + terminal next")
            .frame(minWidth: 800, minHeight: 500)
    }
}
```

**Step 2: Update App to use Window + MenuBarExtra**

Replace `Workforce_for_Claude_CodeApp.swift`:

```swift
import SwiftUI

@main
struct Workforce_for_Claude_CodeApp: App {
    @State private var agentStore = AgentStore()
    @State private var socketServer: SocketServer?

    var body: some Scene {
        Window("Workforce", id: "main") {
            MainWindowView(store: agentStore)
        }

        MenuBarExtra {
            Button("Show Workforce") {
                NSApp.activate()
                for window in NSApp.windows where window.identifier?.rawValue == "main" {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Divider()
            Text("\(agentStore.agents.count) agent\(agentStore.agents.count == 1 ? "" : "s")")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            let hasPermission = agentStore.agents.values.contains { $0.status == .waitingForPermission }
            let hasWaiting = agentStore.agents.values.contains { $0.status == .waitingForInput }

            if hasPermission {
                Image(systemName: "person.3.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .primary)
            } else if hasWaiting {
                Image(systemName: "person.3.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.orange, .primary)
            } else {
                Image(systemName: "person.3.fill")
            }
        }
    }

    init() {
        let store = AgentStore()
        _agentStore = State(initialValue: store)
        let server = SocketServer(store: store)
        _socketServer = State(initialValue: server)
        try? server.start()
        NotificationManager.shared.requestPermission()
    }
}
```

Note: We keep `INFOPLIST_KEY_LSUIElement = YES` so the app doesn't show in the dock by default. The main window is opened via the menu bar item. We may want to change this later so the app appears in the dock when the window is open, but that's a refinement.

**Step 3: Build in Xcode to verify**

Expected: Builds, menu bar icon appears, clicking "Show Workforce" opens the main window.

**Step 4: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Workforce_for_Claude_CodeApp.swift" \
        "Workforce for Claude Code/Workforce for Claude Code/Views/MainWindowView.swift"
git commit -m "feat: replace menu bar popover with main window"
```

---

## Task 6: Tabbed sidebar grouped by working directory (bd-os1.5)

**Files:**
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Views/MainWindowView.swift`

**Step 1: Implement the tabbed layout**

Replace `MainWindowView.swift` with:

```swift
import SwiftUI

struct MainWindowView: View {
    let store: AgentStore
    @State private var selectedCwd: String?
    @State private var selectedAgentId: String?

    /// Unique cwds from all active agents, sorted alphabetically
    private var cwds: [String] {
        Array(Set(store.sortedAgents.map(\.cwd))).sorted()
    }

    /// Agents filtered to the selected cwd tab
    private var filteredAgents: [Agent] {
        guard let cwd = effectiveCwd else { return [] }
        return store.sortedAgents.filter { $0.cwd == cwd }
    }

    /// Effective cwd: selected if still valid, otherwise first available
    private var effectiveCwd: String? {
        if let selectedCwd, cwds.contains(selectedCwd) {
            return selectedCwd
        }
        return cwds.first
    }

    private var selectedAgent: Agent? {
        guard let selectedAgentId else { return filteredAgents.first }
        return store.agents[selectedAgentId]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            tabBar

            Divider()

            // Content: sidebar + terminal
            HSplitView {
                sidebar
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 350)

                terminalPane
            }

            Divider()

            // Footer
            footer
        }
        .frame(minWidth: 800, minHeight: 500)
        .onChange(of: cwds) { _, newCwds in
            if let selectedCwd, !newCwds.contains(selectedCwd) {
                self.selectedCwd = newCwds.first
                self.selectedAgentId = nil
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                store.pruneStale()
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(cwds, id: \.self) { cwd in
                    Button {
                        selectedCwd = cwd
                        selectedAgentId = nil
                    } label: {
                        Text(abbreviatePath(cwd))
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                effectiveCwd == cwd
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear
                            )
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Group {
            if filteredAgents.isEmpty {
                VStack {
                    Spacer()
                    Text("No agents")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredAgents) { agent in
                            AgentRowView(agent: agent) {
                                selectedAgentId = agent.sessionId
                            }
                            .background(
                                selectedAgentId == agent.sessionId
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear
                            )
                            .onTapGesture {
                                selectedAgentId = agent.sessionId
                            }
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Terminal Pane

    private var terminalPane: some View {
        Group {
            if let agent = selectedAgent {
                if agent.tmuxSession != nil {
                    Text("Terminal placeholder for \(agent.name)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .foregroundStyle(.green)
                        .font(.system(.body, design: .monospaced))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No terminal available")
                            .foregroundStyle(.secondary)
                        Text("Start this session with `workforce run` to enable the embedded terminal.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.3.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No agent selected")
                        .foregroundStyle(.secondary)
                    Text("Start a Claude Code session to see it here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(store.agents.count) agent\(store.agents.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HookStatusView()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
```

**Step 2: Extract hook install/uninstall into a small view**

Create `Workforce for Claude Code/Workforce for Claude Code/Views/HookStatusView.swift`:

```swift
import SwiftUI

struct HookStatusView: View {
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var message: String?

    var body: some View {
        HStack(spacing: 6) {
            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if hooksInstalled {
                Button("Uninstall Hooks") { uninstall() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Install Hooks") { install() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    private func install() {
        guard let binary = HookInstaller.findBinary() else {
            message = "workforce binary not found"
            clearMessage()
            return
        }
        do {
            let count = try HookInstaller.install(binaryPath: binary)
            hooksInstalled = true
            message = count > 0 ? "Installed \(count) hooks." : "Hooks already installed."
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
        clearMessage()
    }

    private func uninstall() {
        do {
            let count = try HookInstaller.uninstall()
            hooksInstalled = false
            message = "Removed \(count) hooks."
        } catch {
            message = "Uninstall failed: \(error.localizedDescription)"
        }
        clearMessage()
    }

    private func clearMessage() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            message = nil
        }
    }
}
```

**Step 3: The old ContentView.swift can be deleted**

`Workforce for Claude Code/Workforce for Claude Code/ContentView.swift` is no longer used since MainWindowView replaces it.

**Step 4: Build in Xcode to verify**

Expected: Main window shows tab bar, sidebar, and terminal placeholder.

**Step 5: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Views/MainWindowView.swift" \
        "Workforce for Claude Code/Workforce for Claude Code/Views/HookStatusView.swift"
git rm "Workforce for Claude Code/Workforce for Claude Code/ContentView.swift"
git commit -m "feat: add tabbed sidebar grouped by working directory"
```

---

## Task 7: SwiftTerm terminal view with tmux attach (bd-os1.6)

**Files:**
- Create: `Workforce for Claude Code/Workforce for Claude Code/Views/TerminalView.swift`

**Step 1: Create the NSViewRepresentable wrapper**

```swift
import SwiftUI
import SwiftTerm

/// Wraps SwiftTerm's LocalProcessTerminalView for use in SwiftUI.
/// Attaches to a tmux session by spawning `tmux attach -t <sessionName>`.
struct TerminalRepresentable: NSViewRepresentable {
    let sessionName: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)

        // Find tmux path
        let tmuxPath = findExecutable("tmux") ?? "/opt/homebrew/bin/tmux"

        view.startProcess(
            executable: tmuxPath,
            args: ["attach", "-t", sessionName],
            environment: nil,
            execName: "tmux"
        )

        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // No dynamic updates — session is set at creation time.
        // Switching agents creates a new TerminalRepresentable with a different id.
    }

    /// Find an executable in common paths
    private func findExecutable(_ name: String) -> String? {
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
```

**Step 2: Build in Xcode to verify SwiftTerm imports work**

Expected: Builds successfully with SwiftTerm.

**Step 3: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Views/TerminalView.swift"
git commit -m "feat: add SwiftTerm NSViewRepresentable wrapper for tmux attach"
```

---

## Task 8: Wire agent selection to terminal attachment (bd-os1.7)

**Files:**
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Views/MainWindowView.swift`

**Step 1: Replace terminal placeholder with real SwiftTerm view**

In `MainWindowView.swift`, replace the terminal placeholder block:

```swift
// Replace:
if agent.tmuxSession != nil {
    Text("Terminal placeholder for \(agent.name)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundStyle(.green)
        .font(.system(.body, design: .monospaced))
}

// With:
if let tmuxSession = agent.tmuxSession {
    TerminalRepresentable(sessionName: tmuxSession)
        .id(agent.sessionId) // Force new view when switching agents
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

The `.id(agent.sessionId)` is critical — it forces SwiftUI to destroy and recreate the `TerminalRepresentable` when switching agents, which properly detaches from the old tmux session and attaches to the new one.

**Step 2: Handle notification focus**

Update the `.onReceive` for notification focus to also select the agent in the sidebar. In `MainWindowView`, add:

```swift
.onReceive(NotificationCenter.default.publisher(for: .focusAgent)) { notification in
    if let sessionId = notification.userInfo?["sessionId"] as? String,
       let agent = store.agents[sessionId] {
        selectedCwd = agent.cwd
        selectedAgentId = agent.sessionId
        // Also bring the window to front
        NSApp.activate()
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
```

**Step 3: Build and test in Xcode**

Expected: Selecting an agent with a tmux session shows the terminal. Switching agents swaps the terminal.

**Step 4: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Views/MainWindowView.swift"
git commit -m "feat: wire agent selection to SwiftTerm terminal view"
```

---

## Task 9: Update AgentRowView Focus button behavior (cleanup)

**Files:**
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Views/AgentRowView.swift`

**Step 1: Change Focus button semantics**

The `onFocus` callback in `AgentRowView` currently calls `WindowActivator.activate(agent)` to bring the host terminal to the front. In the new main window layout, this button should select the agent in the sidebar instead. The `onFocus` callback is already wired to `selectedAgentId = agent.sessionId` in the `MainWindowView` sidebar, so the button text should change from "Focus" to "Select" or we can remove it entirely since clicking the row already selects.

Remove the Focus button from AgentRowView since row tap handles selection:

```swift
// Remove:
Button("Focus", action: onFocus)
    .buttonStyle(.borderless)
    .font(.caption)
```

And remove the `onFocus` parameter:

```swift
struct AgentRowView: View {
    let agent: Agent

    var body: some View {
        HStack(spacing: 10) {
            // ... same content but without the Button at the end
        }
    }
}
```

Update all call sites — in `MainWindowView.swift` the `AgentRowView` init no longer needs the closure.

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Views/AgentRowView.swift" \
        "Workforce for Claude Code/Workforce for Claude Code/Views/MainWindowView.swift"
git commit -m "refactor: remove Focus button from AgentRowView, use row tap for selection"
```

---

## Task 10: End-to-end integration test (bd-os1.8)

**Manual testing steps:**

1. Build WorkforceKit: `cd WorkforceKit && swift build`
2. Copy binary: `cp .build/debug/workforce /usr/local/bin/workforce`
3. Build and run the Xcode app
4. Install hooks via the menu bar
5. In a terminal, run: `workforce run`
6. Verify: agent appears in the app sidebar with a tmux session
7. Click the agent — verify SwiftTerm shows the Claude session
8. Start a second `workforce run` in a different directory
9. Verify: a second tab appears for the new cwd
10. Switch between agents — verify terminal swaps correctly
11. Exit Claude in one session — verify agent is removed after cleanup
12. Test `workforce run -- --model sonnet "hello"` — verify args pass through

**Step 1: Run through all steps above**

**Step 2: Fix any issues found**

**Step 3: Final commit if any fixes were needed**
