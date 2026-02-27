# Workforce iOS/iPadOS Client — Implementation Spec

Build a native SwiftUI iOS/iPadOS app that acts as a remote client for one or more Workforce servers. The app connects to Workforce macOS servers, displays real-time agent status, and provides interactive terminal access to agent tmux sessions via SSH.

## Architecture Overview

```
┌────────────────────────────┐                          ┌──────────────────────┐
│  Workforce iOS App         │                          │  Workforce macOS     │
│                            │  HTTP API (REST)         │  (runs agents)       │
│  ServerConnection          │◄────────────────────────►│  HTTPServer :N       │
│  • GET/POST /api/*         │  WebSocket (real-time)   │  WebSocketManager    │
│  • WS /api/ws              │◄────────────────────────►│                      │
│                            │                          │                      │
│  SSHTerminalSession        │  SSH (terminal)          │  tmux sessions       │
│  • swift-nio-ssh           │◄────────────────────────►│  • tmux attach -t X  │
│  • SwiftTerm rendering     │  direct PTY relay        │                      │
└────────────────────────────┘                          └──────────────────────┘
```

Two independent connections to each server:
1. **HTTP + WebSocket** to the Workforce API (port from config) for agent status, spawn, kill
2. **SSH** directly to the host (port 22 or configured) for interactive terminal sessions via `tmux -u attach -t <session>`

---

## Target

- iOS 17+ / iPadOS 17+
- SwiftUI with `@Observable` (Observation framework)
- Swift Package Manager dependencies:
  - **[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)** — native VT100/xterm terminal emulator (UIKit view, wrap in `UIViewRepresentable`)
  - **[swift-nio-ssh](https://github.com/apple/swift-nio-ssh)** — Apple's SSH implementation for terminal transport
- No other third-party dependencies

---

## Data Models

Copy these verbatim. All JSON uses `iso8601` date encoding.

### AgentStatus

```swift
public enum AgentStatus: String, Codable, Sendable {
    case active
    case waitingForInput
    case waitingForPermission
    case idle
    case stopped
}
```

### Agent

```swift
public struct Agent: Codable, Identifiable, Sendable {
    public let sessionId: String
    public var id: String { sessionId }
    public let name: String
    public let avatarSeed: String
    public let cwd: String
    public let agentType: String        // "claude", "codex", "opencode", "bash"
    public let model: String?
    public let tmuxSession: String?
    public var host: String?
    public let startedAt: Date
    public var lastActivityAt: Date
    public var status: AgentStatus
    public var currentToolName: String?
    public var lastNotificationType: String?
    public var subagentCount: Int
    public var paneTitle: String?
    public var transcriptPath: String?
    public var notificationMessage: String?
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var totalCacheCreationTokens: Int
    public var totalCacheReadTokens: Int

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
}
```

### SocketMessage

```swift
public enum SocketMessageType: String, Codable, Sendable {
    case register
    case updateStatus
    case updateTool
    case notification
    case subagentStart
    case subagentStop
    case deregister
    case updateTokens
}

public struct SocketMessage: Codable, Sendable {
    public let type: SocketMessageType
    public let sessionId: String
    public let cwd: String
    public let timestamp: Date
    public var name: String?
    public var avatarSeed: String?
    public var model: String?
    public var status: AgentStatus?
    public var toolName: String?
    public var notificationType: String?
    public var agentType: String?
    public var tmuxSession: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheCreationTokens: Int?
    public var cacheReadTokens: Int?
    public var transcriptPath: String?
    public var notificationMessage: String?
}
```

### WebSocketMessage (for decoding server messages)

```swift
struct WebSocketMessage: Codable {
    let kind: String            // "event" or "snapshot"
    let event: SocketMessage?   // present when kind == "event"
    let agents: [Agent]?        // present when kind == "snapshot"
}
```

### ServerConfig (app-specific, for persistence)

```swift
struct ServerConfig: Codable, Identifiable {
    let id: UUID
    var label: String           // User-facing name, e.g. "Home Mac"
    var host: String            // IP or hostname (used for both API and SSH)
    var port: Int               // Workforce API port
    var apiToken: String        // Bearer token for API auth
    var isEnabled: Bool

    // SSH settings (for terminal access)
    var sshPort: Int            // Default: 22
    var sshUser: String         // SSH username
    var sshAuthMethod: SSHAuthMethod
}

enum SSHAuthMethod: Codable {
    case password(String)
    case keyFile(path: String, passphrase: String?)
    // Future: .agent (SSH agent forwarding not available on iOS)
}
```

---

## Server API Reference

Base URL: `http://<host>:<port>`. All requests require `Authorization: Bearer <token>` header (except OPTIONS). All dates are ISO 8601.

| Method | Path | Body | Response | Notes |
|--------|------|------|----------|-------|
| `GET` | `/api/agents` | — | `[Agent]` | All agents sorted by startedAt |
| `GET` | `/api/agents/:id` | — | `Agent` or 404 | Single agent by sessionId |
| `DELETE` | `/api/agents/:id` | — | `{"ok":true}` or 404 | Kills tmux session + removes agent |
| `POST` | `/api/spawn` | `{"cwd":"~","agentType":"claude"}` | `{"ok":true,"sessionId":"..."}` | Spawn new agent. Allowed types: `claude`, `codex`, `opencode`, `bash`. Allowed flag: `--dangerously-skip-permissions` |
| `POST` | `/api/events` | `SocketMessage` JSON | `{"ok":true}` | Submit an event (rarely needed from iOS) |
| `POST` | `/api/clients/register` | `{"clientId":"...","hostname":"...","user":"..."}` | `{"ok":true}` | Register as a connected client |
| `GET` | `/api/clients` | — | `[ConnectedClient]` | List connected clients |

### WebSocket Endpoint

`GET /api/ws?token=<apiToken>` with standard WebSocket upgrade headers.

**Server → Client messages** (JSON text frames):
```json
// Snapshot (sent immediately on connect, and on request)
{"kind": "snapshot", "event": null, "agents": [<Agent>, ...]}

// Incremental event (sent on every state change)
{"kind": "event", "event": <SocketMessage>, "agents": null}
```

**Client → Server messages:**
```json
{"action": "snapshot"}   // Request a fresh snapshot
```

**Keepalive:** Server sends ping frames every 30s.

---

## App Structure

### Service Layer

#### `ServerConnection` — One per configured server

Manages the HTTP API + WebSocket lifecycle for a single server:

1. On `connect()`: Make a test `GET /api/agents` request to verify connectivity.
2. On success: Open a `URLSessionWebSocketTask` to `ws://<host>:<port>/api/ws?token=<token>`.
3. Process incoming messages:
   - `kind: "snapshot"` → replace `agents` array entirely (set `host` to server label on each agent)
   - `kind: "event"` → apply incremental update (same logic as macOS `RemoteHostManager.applyEvent`)
4. On WS failure: set `useWebSocket = false`, fall back to polling `GET /api/agents` every 10s.
5. On WS restore: stop polling, resume real-time updates.
6. Register as a client via `POST /api/clients/register` on first connect and every 60s thereafter (use `UIDevice.current.name` as hostname, a stable UUID from UserDefaults as clientId).

State exposed to the UI:
```swift
@Observable
class ServerConnection {
    let config: ServerConfig
    var status: ConnectionStatus    // .disconnected, .connecting, .connected, .error(String)
    var agents: [Agent] = []
    var useWebSocket: Bool = false
}
```

#### `SSHTerminalSession` — One per open terminal

Manages an SSH connection + PTY channel to a single tmux session. This is separate from `ServerConnection` — the API connection handles status/control, while `SSHTerminalSession` handles interactive terminal I/O.

```swift
@Observable
class SSHTerminalSession {
    let serverConfig: ServerConfig
    let tmuxSession: String
    var isConnected: Bool = false
    var error: String?

    func connect() async throws
    func disconnect()
    func send(_ data: Data)             // Write to remote PTY
    var onData: ((Data) -> Void)?       // Callback when data arrives from remote PTY
    func resize(cols: Int, rows: Int)   // Send window-change request
}
```

**Connection flow:**
1. Open SSH connection to `config.host:config.sshPort` using `swift-nio-ssh` with the configured auth method.
2. Open a session channel, request a PTY (`xterm-256color`, initial size from SwiftTerm), then exec `tmux -u attach -t <tmuxSession>`.
3. Relay data bidirectionally:
   - SSH channel data → `onData` callback → SwiftTerm's `feed(byteArray:)` or `feed(text:)`
   - SwiftTerm user input → `send(_ data:)` → SSH channel write
4. Handle `resize()` by sending SSH window-change requests.
5. On disconnect or error, clean up the channel and SSH connection.

**Reference implementation:** SwiftTerm's own repo has `UIKitSshTerminalView` in the iOS sample that demonstrates exactly this pattern with `swift-nio-ssh`. Use it as a starting point.

#### `ServerManager` — Singleton / environment object

Manages all `ServerConnection` instances. Provides:
- `var connections: [UUID: ServerConnection]`
- `var allAgents: [Agent]` (flattened from all connections)
- `func addServer(_ config: ServerConfig)`
- `func removeServer(_ id: UUID)`
- `func connectAll()` / `disconnectAll()`
- Persists `[ServerConfig]` to a JSON file in the app's documents directory. **Store `SSHAuthMethod` securely** — passwords and key passphrases should go in the iOS Keychain, not plain JSON.
- Handles app lifecycle: connect on `scenePhase == .active`, disconnect on `.background` (to save battery).

#### `CostCalculator` — Static utility

```swift
enum CostCalculator {
    // Pricing (USD per million tokens):
    // claude-opus-4-6:   input $15.00, output $75.00
    // claude-sonnet-4-6: input $3.00,  output $15.00
    // claude-haiku-4-5:  input $0.80,  output $4.00
    // default:           input $3.00,  output $15.00

    static func estimateCost(model: String?, inputTokens: Int, outputTokens: Int,
                             cacheCreationTokens: Int, cacheReadTokens: Int) -> Double
    // input / 1M * inputRate + output / 1M * outputRate
    // + cacheCreation / 1M * inputRate * 1.25
    // + cacheRead / 1M * inputRate * 0.1

    static func formatCost(_ cost: Double) -> String     // "$1.23" or "<$0.01"
    static func formatTokens(_ count: Int) -> String     // "1.2M", "4.5k", or "123"
}
```

---

## UI Specification

### Navigation Structure

Use a `NavigationSplitView` with two columns:

```
iPad (landscape):
┌──────────────┬──────────────────────────────────────┐
│  Sidebar     │  Detail (terminal / server overview)  │
│  (320pt)     │  (fills remaining width)              │
│              │                                        │
│  Servers     │                                        │
│  └ cwd       │                                        │
│    └ agents  │                                        │
│              │                                        │
└──────────────┴──────────────────────────────────────┘

iPhone:
┌─────────────────┐     ┌─────────────────┐
│  Sidebar         │────►│  Agent Detail    │
│  (full screen)   │ tap │  (full screen    │
│                  │     │   with terminal) │
│                  │     │   ◄ Back         │
└─────────────────┘     └─────────────────┘
```

- **Sidebar** is always visible on iPad alongside the terminal. The user taps agents in the sidebar to switch which terminal is shown in the detail pane. This is the primary way to switch between agents.
- **On iPhone**, the sidebar is a navigation stack — tapping an agent pushes the detail view. Swipe back to return to the sidebar.
- The sidebar selection state (`@State var selectedAgentId: String?`) drives which agent's terminal is shown.

### Screens

#### 1. Sidebar (Agent Switcher)

The sidebar is the **agent switcher**. It shows all servers and their agents in a scrollable list. The currently selected agent is highlighted.

**Structure:**
```
[+] [Settings]                      ← toolbar
─────────────────────────────────
▼ Home Mac (●)                      ← server header (green dot = connected)
  ▼ ~/Projects/myapp                ← cwd group
    ● Fixing auth bug     $1.23     ← agent row (selected, highlighted)
    ● Claude              $0.45     ← agent row
  ▼ ~/Projects/other
    ○ Claude              $0.02     ← idle agent (static dot)
▼ Work Mac (●)
  ▼ ~/work/api
    ◉ Waiting for input   $2.10     ← orange dot, waiting
─────────────────────────────────
```

**Server header row:**
- Disclosure chevron (▶/▼) to collapse/expand
- Connection status dot (green/yellow/red/gray)
- Server label
- Agent count badge (right-aligned)

**CWD group row:**
- Disclosure chevron
- Folder icon + abbreviated path (`~` for home dir)

**Agent row:**
- Status dot (colored, pulsing when active)
- `displayTitle` (primary text)
- Agent type badge pill (only if not "claude", e.g. "bash", "codex")
- Subagent count badge pill (only if > 0)
- Estimated cost (right-aligned, monospaced)
- `currentToolName` as secondary text when status is active

**Selection behavior:**
- Tapping an agent row sets `selectedAgentId` and shows that agent's terminal in the detail pane.
- The selected row gets a highlight background (`.accentColor.opacity(0.1)`).
- On iPad, switching agents in the sidebar instantly swaps the terminal in the detail pane (the previous SSH session stays alive in the pool).

**Empty state:** "No servers configured. Tap + to add one."

**Toolbar:**
- `+` button → Add Server sheet
- Gear button → Settings

**Context menus (long-press):**
- On agent row: "Agent Info", "Copy Session ID", "Kill Agent" (destructive)
- On server header: "Edit Server", "Spawn Agent", "Disconnect"

#### 2. Add/Edit Server Sheet

Form with sections:

**Server section:**
- Label (text field, required)
- Host (text field, required, placeholder: "192.168.1.100")
- API Port (text field, numeric keyboard, required)
- API Token (secure text field, required)
- Enabled (toggle)

**SSH section (for terminal access):**
- SSH Port (text field, numeric, default: "22")
- SSH Username (text field, required)
- Auth Method picker: Password / Key File
  - If Password: secure text field
  - If Key File: file path field + passphrase (optional, secure text field)

**Actions:**
- "Test API Connection" button → tries `GET /api/agents` and reports success/failure
- "Test SSH Connection" button → tries SSH connect + disconnect and reports success/failure

#### 3. Agent Detail View (Detail Pane)

This is the **detail pane** — shown to the right of the sidebar on iPad, or pushed on iPhone. It is driven by `selectedAgentId` from the sidebar. The terminal dominates the view.

**Layout (iPad — detail pane next to sidebar):**
```
┌──────────────────────────────────────────────┐
│  Header bar (compact, single line)           │
│  ● displayTitle  ·  cwd  ·  $cost    [ⓘ][🗑]│
├──────────────────────────────────────────────┤
│                                              │
│  Terminal (SwiftTerm)                        │
│  (fills all remaining space)                 │
│  User switches agents via sidebar —          │
│  terminal swaps instantly                    │
│                                              │
│                                              │
│                                              │
│                                              │
└──────────────────────────────────────────────┘
```

**Layout (iPhone — full screen, pushed from sidebar):**
```
┌─────────────────────────────┐
│  ◄ Back   displayTitle  [ⓘ]│
│  ● status · cwd · $cost    │
├─────────────────────────────┤
│                             │
│  Terminal (SwiftTerm)       │
│  (fills remaining space)    │
│                             │
│                             │
│                             │
│                             │
├─────────────────────────────┤
│  [Kill Agent] toolbar       │
└─────────────────────────────┘
```

**Terminal behavior:**
- When the agent has a `tmuxSession`, automatically create an `SSHTerminalSession` and connect.
- Render in a `SwiftTermView` (UIViewRepresentable wrapping SwiftTerm's `TerminalView`).
- If the agent has no `tmuxSession` (rare — means it wasn't started via Workforce), show a "No terminal session available" placeholder.
- If SSH connection fails, show the error inline with a "Retry" button, and show the agent info cards as fallback content.
- The terminal should handle the iOS software keyboard properly — SwiftTerm supports this natively.
- On iPad with hardware keyboard, the terminal should capture all key input.

**Info sheet** (presented as a sheet from the toolbar Info button):
- **Status**: Current status, tool name if active, last activity relative time
- **Tokens**: Input / Output / Cache Creation / Cache Read (formatted with `formatTokens`)
- **Cost**: Estimated cost (formatted)
- **Session Info**: agentType, model, sessionId, subagent count, tmuxSession name

**Action buttons (in bottom toolbar):**
- **Info** (ⓘ) → presents the info sheet
- **Kill Agent** (trash, destructive, with confirmation) → `DELETE /api/agents/:id`

#### 4. Server Detail View (when server is selected but no agent)

Overview for one server:
- Connection status (API + SSH reachability)
- Total agents, total cost
- Agent breakdown by status (counts)
- "Spawn Agent" button → shows picker for agent type (claude, claude --dangerously-skip-permissions, bash), cwd input (defaults to "~") → `POST /api/spawn`

#### 5. Settings

- List of configured servers with edit/delete
- Global: show costs toggle
- About section

---

## Terminal Implementation Detail

### SwiftTermView (UIViewRepresentable)

Wraps SwiftTerm's `TerminalView` for SwiftUI. Responsibilities:

1. **Create** a `TerminalView` (from SwiftTerm package) in `makeUIView`.
2. **Wire up** the `SSHTerminalSession`:
   - `session.onData = { data in terminalView.feed(byteArray: [UInt8](data)) }`
   - Implement `TerminalViewDelegate.send(source:data:)` → `session.send(data)`
   - Implement `TerminalViewDelegate.sizeChanged(source:newCols:newRows:)` → `session.resize(cols:rows:)`
3. **Configure** the terminal appearance:
   - Font: system monospace or bundled Nerd Font (see below)
   - Theme: dark background (`#1e1e1e`) matching the macOS app
   - Scrollback: 10000 lines
4. **Lifecycle**: connect SSH session in `makeUIView`, disconnect in `dismantleUIView` (or via `onDisappear`).

### Font

The macOS app bundles JetBrains Mono Nerd Font. For iOS:
- Bundle the same `.ttf` files in the iOS app.
- Register them via `Info.plist` → `UIAppFonts` array (or `CTFontManagerRegisterFontsForURL`).
- Set as the terminal font: `terminalView.font = UIFont(name: "JetBrainsMonoNFM-Regular", size: 13)`
- If font registration fails, fall back to `UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)`.

### Terminal Theme

Match the macOS app's VS Code Dark theme:
```swift
let theme = SwiftTerm.Theme(
    background: UIColor(red: 0x1e/255, green: 0x1e/255, blue: 0x1e/255, alpha: 1),
    foreground: UIColor(red: 0xd4/255, green: 0xd4/255, blue: 0xd4/255, alpha: 1),
    cursor: UIColor(red: 0xd4/255, green: 0xd4/255, blue: 0xd4/255, alpha: 1),
    // ANSI colors:
    // black: #000000, red: #cd3131, green: #0dbc79, yellow: #e5e510
    // blue: #2472c8, magenta: #bc3fbc, cyan: #11a8cd, white: #e5e5e5
    // brightBlack: #666666, brightRed: #f14c4c, brightGreen: #23d18b, brightYellow: #f5f543
    // brightBlue: #3b8eea, brightMagenta: #d670d6, brightCyan: #29b8db, brightWhite: #e5e5e5
)
```

### SSH Connection via swift-nio-ssh

Reference: SwiftTerm's iOS sample has `UIKitSshTerminalView` that demonstrates the full pattern. Key steps:

1. Create an `NIOSSHClient` connection to `host:sshPort`.
2. Authenticate using the configured method (password or public key).
3. Open a session channel.
4. Request a PTY with `TERM=xterm-256color` and the terminal's current dimensions.
5. Exec `tmux -u attach -t <tmuxSession>`.
6. Read channel data → feed to SwiftTerm.
7. SwiftTerm delegate sends user input → write to channel.
8. On terminal resize → send SSH window-change request.
9. On disconnect: close channel, close SSH connection.

### Multiple Terminal Sessions

Each agent gets its own `SSHTerminalSession` instance. When the user switches agents in the sidebar, the previous terminal stays alive in the background (don't disconnect SSH immediately). Use a cache/pool in `ServerManager`:

```swift
var terminalSessions: [String: SSHTerminalSession] = [:]  // keyed by sessionId

func terminalSession(for agent: Agent, config: ServerConfig) -> SSHTerminalSession {
    if let existing = terminalSessions[agent.sessionId] { return existing }
    let session = SSHTerminalSession(serverConfig: config, tmuxSession: agent.tmuxSession!)
    terminalSessions[agent.sessionId] = session
    return session
}
```

Evict sessions when:
- The agent is removed/killed
- The app goes to background (disconnect all SSH sessions to save battery)
- Memory pressure (evict least-recently-used)

---

## Push Notifications

When a WebSocket event arrives with `type == .notification` and `status` transitions to `.waitingForInput` or `.waitingForPermission`:

1. Post a local `UNNotificationRequest`:
   - Title: `agent.notificationMessage ?? agent.displayTitle`
   - Body: `"<serverLabel>: <statusDescription>"`
   - Identifier: `"workforce-<sessionId>"` (replaces previous for same agent)
   - Category: `"AGENT_WAITING"`
2. On notification tap: navigate to that agent's detail view (which opens the terminal)

Request notification permissions on first launch.

When the app is in the foreground, show an in-app banner instead (using `.sensoryFeedback` or a custom overlay).

---

## Background Behavior

- When `scenePhase == .background`:
  - **Disconnect all SSH terminal sessions** immediately (save battery, iOS will kill them anyway)
  - Keep WebSocket API connections alive for ~30 seconds (iOS allows this for status updates / notifications)
  - After iOS suspends the app, API connections will drop — that's fine
- On returning to `.active`:
  - Reconnect all `ServerConnection` API/WS connections
  - **Do NOT auto-reconnect SSH sessions** — reconnect lazily when the user navigates to an agent's terminal
- Do NOT use background app refresh or BGTaskScheduler — keep it simple.

---

## iPad-Specific Adaptations

- `NavigationSplitView` shows sidebar (320pt) + terminal side by side. The sidebar is the agent switcher — tapping agents swaps the terminal in the detail pane without navigation transitions. Use `.navigationSplitViewStyle(.balanced)` or `.prominentDetail` depending on which feels better for terminal focus.
- **Sidebar visibility**: Use `NavigationSplitViewVisibility` — default to `.all` (sidebar visible). The user can hide the sidebar to give the terminal full width, and show it again to switch agents.
- Hardware keyboard: full key passthrough to terminal (including Ctrl+C, Ctrl+Z, arrow keys, etc.). When the terminal is focused, it should capture all keyboard input.
- Support keyboard shortcuts:
  - `Cmd+N` → Add server
  - `Cmd+R` → Refresh all (request snapshot on all WS connections)
  - `Cmd+K` → Clear terminal scrollback
  - `Cmd+1..9` → Switch to agent 1..9 in sidebar order
- Multitasking: terminal should resize properly in Split View and Slide Over. SwiftTerm handles this via its delegate's `sizeChanged` callback — make sure to forward resize events to the SSH session.

---

## Key Implementation Notes

1. **All JSON decoding uses `.iso8601` date strategy.** The server sends ISO 8601 dates everywhere.

2. **The WebSocket URL includes the token as a query param**, not as a header. `URLSessionWebSocketTask` does not support custom headers on the upgrade request, so the server accepts `?token=<token>`.

3. **Applying incremental events** — when a `kind: "event"` message arrives, update the local agents array:
   - `register` → add/replace agent with matching sessionId
   - `deregister` → remove agent with matching sessionId
   - `updateStatus` → find agent, update `status`, `lastActivityAt`
   - `updateTool` → find agent, update `currentToolName`, `status`, `lastActivityAt`
   - `notification` → find agent, update `lastNotificationType`, `notificationMessage`, `transcriptPath`, `status`, `lastActivityAt`
   - `subagentStart` → find agent, increment `subagentCount`, update `lastActivityAt`
   - `subagentStop` → find agent, decrement `subagentCount` (min 0), update `lastActivityAt`
   - `updateTokens` → find agent, update `totalInputTokens`, `totalOutputTokens`, `totalCacheCreationTokens`, `totalCacheReadTokens`, update `lastActivityAt`

4. **`host` field on Agent** — When receiving agents from a server, set `agent.host` to the server's label (for display purposes). The server itself doesn't set this field for its local agents.

5. **Name generation** is deterministic from `sessionId` — you don't need `NameGenerator` on iOS since agent names come from the server. Just display `agent.name`.

6. **Avatar URLs** — The macOS app uses DiceBear: `https://api.dicebear.com/9.x/bottts-neutral/png?seed=<avatarSeed>&size=64`. Use `AsyncImage` with this URL for agent avatars. Cache with `URLCache`.

7. **Cost calculation** — Use the same formula as macOS:
   - Cache creation costs 1.25x the input rate
   - Cache read costs 0.1x the input rate
   - Model lookup falls back to sonnet pricing if model is nil or unrecognized

8. **Polling fallback interval** — 10 seconds when WebSocket is unavailable. When WebSocket is active, no polling needed.

9. **Client registration** — On connect, POST to `/api/clients/register` with:
   ```json
   {
     "clientId": "<stable UUID from UserDefaults>",
     "hostname": "<UIDevice.current.name>",
     "user": "ios"
   }
   ```
   Re-register every 60 seconds to avoid being pruned (server prunes after 90s).

10. **Allowed spawn types** — The server validates these. Base commands: `claude`, `codex`, `opencode`, `bash`. Only allowed flag: `--dangerously-skip-permissions`. Present these as preset options, not a free-text field.

11. **SSH is independent of the API connection.** The API uses the Workforce HTTP port + token. SSH goes directly to the host's SSH daemon on `sshPort`. They are completely separate connections. An agent might be visible via the API but SSH might fail (wrong credentials, SSH disabled, etc.) — handle this gracefully by showing agent info without a terminal.

12. **tmux -u flag** — Always use `-u` (force UTF-8) when attaching to tmux sessions, matching the macOS app behavior: `tmux -u attach -t <sessionName>`.

13. **Secure credential storage** — SSH passwords and key passphrases MUST be stored in the iOS Keychain, not in UserDefaults or plain JSON files. Use `Security.framework` (`SecItemAdd`/`SecItemCopyMatching`) or a thin wrapper.

---

## File Structure

```
WorkforceRemote/
├── WorkforceRemoteApp.swift              // @main, setup ServerManager, request notifications
├── Models/
│   ├── Agent.swift                       // Agent, AgentStatus
│   ├── SocketMessage.swift               // SocketMessage, SocketMessageType, WebSocketMessage
│   └── ServerConfig.swift                // ServerConfig, SSHAuthMethod
├── Services/
│   ├── ServerConnection.swift            // Per-server API + WS lifecycle, event application
│   ├── ServerManager.swift               // Manages all connections + terminal session pool
│   ├── SSHTerminalSession.swift          // swift-nio-ssh connection + PTY channel for one tmux session
│   ├── CostCalculator.swift              // Token cost estimation
│   ├── NotificationService.swift         // Local notification posting
│   └── KeychainService.swift             // Secure storage for SSH credentials
├── Views/
│   ├── ContentView.swift                 // NavigationSplitView root
│   ├── ServerListView.swift              // Sidebar with servers + agents
│   ├── AgentRowView.swift                // Agent list row
│   ├── AgentDetailView.swift             // Terminal + agent header + actions
│   ├── SwiftTermView.swift               // UIViewRepresentable wrapping SwiftTerm TerminalView
│   ├── ServerDetailView.swift            // Server overview + spawn
│   ├── AddServerSheet.swift              // Add/edit server form (API + SSH config)
│   ├── AgentInfoSheet.swift              // Agent detail info (tokens, cost, session info)
│   ├── SettingsView.swift                // App settings
│   └── Components/
│       ├── StatusDot.swift               // Pulsing/static colored dot
│       ├── CostBadge.swift               // Formatted cost display
│       └── AgentTypeBadge.swift          // Small pill badge
├── Resources/
│   ├── JetBrainsMonoNerdFontMono-Regular.ttf
│   ├── JetBrainsMonoNerdFontMono-Bold.ttf
│   ├── JetBrainsMonoNerdFontMono-Italic.ttf
│   └── JetBrainsMonoNerdFontMono-BoldItalic.ttf
└── Info.plist                            // UIAppFonts for Nerd Font registration
```

---

## What NOT to Build

- No SSH tunnel management for the API connection — assume the Workforce API port is reachable (via Tailscale/WireGuard/port forward). SSH is only used for terminal sessions.
- No hook installation or CLI management
- No event viewer/log — keep it focused on the dashboard + terminal
- No beads/issue tracking integration
- No transcript reading
- No local agent execution
