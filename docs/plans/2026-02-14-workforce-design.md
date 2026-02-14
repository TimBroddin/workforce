# Workforce for Claude Code — Design Document

## Overview

A macOS menu bar app + CLI tool that tracks all running Claude Code instances, shows their status, and delivers actionable notifications that focus the correct host window when clicked.

## Problem

When running many Claude Code sessions across Terminal, iTerm, VS Code, and Cursor, it's hard to know which agents need attention and hard to navigate to them.

## Solution

**Approach A: Monolithic App + Embedded CLI**

- A menu bar app listens on a Unix domain socket
- A bundled CLI binary (`workforce`) is called by Claude Code hooks on every lifecycle event
- The app shows all active agents with status, dicebear avatars, and generated names
- Native macOS notifications fire when an agent needs input and its host app isn't focused
- Clicking a notification or "Focus" button activates the correct terminal window/tab

## Data Model

```swift
struct Agent: Codable, Identifiable {
    let sessionId: String
    var id: String { sessionId }

    let name: String                // deterministic adjective+animal from sessionId
    let avatarSeed: String          // seed for dicebear API

    let cwd: String
    let hostApp: HostApp            // terminal, iterm, vscode, cursor, warp, unknown
    let hostWindowId: String?
    let hostTabId: String?

    let startedAt: Date
    var lastActivityAt: Date
    var status: AgentStatus         // active, waitingForInput, waitingForPermission, idle, stopped
    var currentToolName: String?
    var lastNotificationType: String?
}

enum AgentStatus: String, Codable {
    case active, waitingForInput, waitingForPermission, idle, stopped
}

enum HostApp: String, Codable {
    case terminal, iterm, vscode, cursor, warp, unknown
}
```

## Architecture

```
Claude Code Hook → workforce CLI → Unix socket → Workforce App → UI / Notifications
```

- **CLI** (`workforce`): Thin client. Subcommands: `session-start`, `pre-tool-use`, `post-tool-use`, `post-tool-use-failure`, `notification`, `stop`, `subagent-start`, `subagent-stop`, `session-end`, `install-hooks`, `uninstall-hooks`. Reads JSON from stdin, sends to socket, exits. Fire-and-forget, <50ms target.
- **Socket Server**: Listens on `/tmp/workforce-{uid}.sock`. Receives JSON, updates agent store.
- **Agent Store**: In-memory `@Observable` dictionary. No persistence — agents self-heal on next hook event.
- **Host Detection**: CLI walks process tree via `getppid()` + `sysctl` to find Terminal.app / iTerm2 / VS Code / etc.
- **Window Activation**: AppleScript for Terminal/iTerm, `open -a` for VS Code/Cursor, Accessibility APIs as fallback.
- **Notifications**: `UNUserNotification` when agent transitions to waiting and host app isn't frontmost.

## Menu Bar UI

- Menu bar icon with status indicator (neutral / orange dot for waiting / red for permission)
- Popover shows agent list sorted by status (waiting states first)
- Each row: dicebear avatar, generated name, status pill, cwd, host app, current tool, Focus button
- Settings: notification preferences, avatar style, stale agent cleanup
- `LSUIElement=true` — no dock icon

## Hook Configuration

The `workforce install-hooks` command merges hooks into `~/.claude/settings.json` for all lifecycle events: SessionStart, PreToolUse, PostToolUse, PostToolUseFailure, Notification, SubagentStart, SubagentStop, Stop, SessionEnd. Each hook calls `/usr/local/bin/workforce <event>`. Existing hooks are preserved.

## Project Structure

```
workforce/
├── Workforce.xcworkspace
├── WorkforceApp/                  # Menu bar app (Xcode target)
│   ├── WorkforceApp.swift
│   ├── Views/
│   ├── Services/
│   └── Assets.xcassets/
├── WorkforceKit/                  # Shared Swift Package
│   ├── Package.swift
│   └── Sources/WorkforceKit/
│       ├── Models/
│       ├── HostDetection.swift
│       ├── NameGenerator.swift
│       └── SettingsManager.swift
├── WorkforceCLI/                  # CLI executable (Swift Package)
│   └── Sources/WorkforceCLI/
│       ├── main.swift
│       ├── Commands/
│       └── SocketClient.swift
└── Package.swift
```

**Dependencies:** swift-argument-parser, SwiftNIO (or Foundation NWListener)

## Edge Cases

1. **App not running** — CLI exits 0 silently on connection refused
2. **App restarts** — Agents self-heal on next hook event
3. **Session crashes (no SessionEnd)** — 5-minute stale check, verify with `ps`
4. **Multiple users** — Socket path includes UID
5. **Stale socket file** — App checks on startup, removes if stale
6. **Rapid events** — Concurrent socket handling, SwiftUI batches redraws
7. **Host app closed** — Graceful fallback to opening Workforce popover
8. **`/usr/local/bin` not writable** — Fall back to `~/.local/bin`, warn about PATH
9. **Existing hooks** — Append-only, identified by `workforce` in command string
10. **Dicebear avatars** — Cached locally after first fetch, PNG endpoint for simplicity
