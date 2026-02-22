# CLI Commands: list, attach, tui

## Overview

Add three new CLI subcommands to `workforce`: `list`, `attach`, and `tui`. These allow users to discover, inspect, and connect to running agent sessions from the terminal.

## Data Source

The CLI uses a **socket-first, tmux-fallback** strategy:

1. **Primary:** Query the Workforce app via a new HTTP API server on localhost
2. **Fallback:** Query tmux directly for `workforce-*` sessions (works when app is not running)

## HTTP API Server (App-side)

Add an `HTTPServer` service to the SwiftUI app using `NWListener` with TCP on localhost.

**Port discovery:** Server binds to port `0` (OS-assigned), writes the actual port to `/tmp/workforce-<uid>.port`. CLI reads this file.

**Endpoints:**

| Method | Path | Response |
|--------|------|----------|
| `GET` | `/api/agents` | JSON array of all `Agent` objects |
| `GET` | `/api/agents/:id` | Single agent by sessionId |

**Implementation:** Minimal HTTP parsing over `NWListener` TCP — parse `GET` request line, return JSON with `Content-Type: application/json`. No external dependencies.

## CLI Commands

### `workforce list`

Display all sessions in a table:

```
SESSION          AGENT     STATUS    CWD                              TITLE
workforce-a1b2c3 claude    active    ~/Projects/my-app                Implementing auth
workforce-d4e5f6 codex     idle      ~/Projects/api-server            codex
workforce-789abc opencode  waiting   ~/Projects/workforce             Adding CLI commands
```

- Columns: session name, agent type, status, cwd (shortened with `~`), display title
- `--json` flag for machine-readable JSON output

### `workforce attach <target>`

Attach to a tmux session by name or partial ID:

```
workforce attach workforce-a1b2c3
workforce attach a1b2c3
```

- Resolves target: exact match on session name, then partial match on ID suffix
- Queries HTTP API for tmux session name, falls back to tmux directly
- Runs `tmux attach-session -t <tmux-session>`
- Prints error with suggestions if no match or multiple matches

### `workforce tui`

Interactive ncurses-based session picker:

```
┌─ Workforce Sessions ─────────────────────────────────────────┐
│                                                               │
│  ● workforce-a1b2c3  claude    active   ~/Projects/my-app     │
│  ○ workforce-d4e5f6  codex     idle     ~/Projects/api-server │
│  ◉ workforce-789abc  opencode  waiting  ~/Projects/workforce  │
│                                                               │
│  ↑↓ navigate  ⏎ attach  q quit  r refresh                    │
└───────────────────────────────────────────────────────────────┘
```

- Uses `Darwin.ncurses` (built-in, no external dependency)
- Arrow keys to navigate, Enter to attach, `q` to quit, `r` to refresh
- Status dots with colors (green=active, gray=idle, blue=waiting)
- Auto-refreshes every 3 seconds
- On Enter: exits ncurses, runs `tmux attach-session`

## Architecture

### New Files

**App-side:**
- `Workforce/Services/HTTPServer.swift` — HTTP API server

**CLI-side (WorkforceKit/Sources/WorkforceCLI/):**
- `Commands/ListCommand.swift` — `workforce list`
- `Commands/AttachCommand.swift` — `workforce attach`
- `Commands/TUICommand.swift` — `workforce tui`
- `APIClient.swift` — HTTP client to query the app's API
- `TmuxFallback.swift` — Direct tmux queries when app is unavailable
- `TUIRenderer.swift` — ncurses rendering logic

### Modified Files

- `Workforce.swift` — Register new subcommands
- `WorkforceApp.swift` — Start HTTP server alongside socket server

### Agent Model

Already has all needed fields: `sessionId`, `agentType`, `status`, `cwd`, `tmuxSession`, `paneTitle`. The `Agent` struct is `Codable` and shared via `WorkforceKit`.

## Tmux Fallback

When the HTTP API is unreachable, the CLI builds a reduced `Agent` list by:

1. `tmux list-sessions -F "#{session_name}"` — filter for `workforce-*`
2. For each session: `tmux display-message -t <name> -p "#{pane_current_path}"` — get cwd
3. For each session: `tmux display-message -t <name> -p "#{pane_title}"` — get title

Fallback agents have `status: .idle` and `agentType: "claude"` (defaults, since this info isn't available from tmux alone).
