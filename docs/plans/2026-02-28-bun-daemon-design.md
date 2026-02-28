# Bun Daemon Architecture — Replace tmux with Native PTY

**Date:** 2026-02-28
**Status:** Design approved

## Problem

The current architecture relies on tmux as a session multiplexer for agent processes. This causes three pain points:

1. **tmux is a hard dependency** — users must have it installed, paths vary across systems
2. **Unnecessary layer** — tmux sits between the user and the agent process, adding complexity
3. **Resize handling is painful** — coordinating terminal sizes between the macOS app's terminal view and CLI through tmux is difficult

## Solution

Replace tmux with a **Bun daemon process** that owns agent PTYs directly. The CLI is rewritten in Bun/TypeScript. The macOS app becomes a thin UI client. Everything communicates over WebSocket.

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  CLI client  │     │  macOS app   │     │  Web UI (?)  │
│  (Bun)       │     │  (SwiftUI)   │     │  (future)    │
└──────┬───────┘     └──────┬───────┘     └──────┬───────┘
       │ WebSocket          │ WebSocket          │ WebSocket
       └────────────┬───────┴────────────────────┘
                    │
           ┌────────▼────────┐
           │   Bun Daemon     │
           │                  │
           │  HTTP API        │
           │  WebSocket hub   │
           │  PTY manager     │
           │  Agent store     │
           │  Hook receiver   │
           └────────┬─────────┘
                    │ PTY (native)
        ┌───────────┼───────────┐
        ▼           ▼           ▼
    [claude]    [opencode]   [codex]
```

Key changes from today:
- tmux is no longer required (optional via `--tmux`/`--zellij` flag)
- CLI rewritten in Bun/TypeScript (distributable via `bunx`/`bun install -g`)
- Daemon manages PTYs directly via Bun's native PTY support
- macOS app becomes a UI client (phase 2; keeps working as-is during phase 1)
- One WebSocket protocol for terminal I/O, agent state, and resize events

## Daemon Design

### Process Management
- Bun process, started via `launchd` (plist installed by `workforce install`) or on-demand by CLI
- PID file at `~/.workforce/daemon.pid`, port at `~/.workforce/daemon.port`, auth token at `~/.workforce/daemon.token`
- Listens on `localhost:<dynamic-port>` (avoids port conflicts)
- Graceful shutdown: sends SIGHUP to agents, waits, then kills

### PTY Management
- Each agent gets a native Bun PTY (`Bun.spawn` with `pty: true`)
- Daemon holds the PTY file descriptor — agent survives CLI disconnect
- Terminal size tracked per-agent, resized when clients connect/disconnect
- Output buffered (scrollback ring buffer, ~10K lines) so reconnecting clients see recent history

### Resize Strategy
- Each connected client reports its terminal size
- When multiple clients are attached to the same agent, daemon uses the smallest dimensions (same as tmux behavior)
- Resize events sent as WebSocket control messages

### Agent State Persistence
- Agent metadata stored in `~/.workforce/agents.json`
- On daemon restart, orphaned child processes are re-adopted if still running, or marked as dead

### Auth
- Random token generated on first start, written to `~/.workforce/daemon.token` (mode 0600)
- Required as Bearer token on HTTP and as query param on WebSocket upgrade

## WebSocket Protocol

Two types of WebSocket connections:

### Control WebSocket (`/ws/control?token=...`)
One per client. Carries JSON text frames for agent state and events:

```typescript
// Client → Daemon
{ type: "spawn", agentType: "claude", cwd: "/path" }
{ type: "kill", agentId: "abc123" }
{ type: "snapshot" }                            // request full agent list

// Daemon → Client
{ type: "agents", agents: [...] }              // snapshot response
{ type: "event", event: {...} }                // agent state change
{ type: "spawned", agentId: "abc123" }         // spawn response
{ type: "error", message: "..." }
```

### Terminal WebSocket (`/ws/terminal/:id?token=...`)
One per agent attachment. Carries raw terminal data:

- **Binary frames** = raw PTY bytes (stdout from agent, stdin from client). No wrapping, no JSON.
- **Text frames** = JSON control messages for that terminal session:

```typescript
// Client → Daemon
{ type: "resize", cols: 120, rows: 40 }

// Daemon → Client
{ type: "scrollback", data: "base64..." }      // sent on connect, recent history
```

This separation means:
- CLI opens 2 connections: 1 control + 1 terminal
- macOS app opens 1 control + N terminal connections (one per visible terminal)
- Binary frames are unambiguous — each WebSocket maps to exactly one agent

## HTTP API

```
GET    /api/agents              # List all agents
GET    /api/agents/:id          # Get single agent
POST   /api/agents              # Spawn new agent { agentType, cwd, flags? }
DELETE /api/agents/:id          # Kill agent
POST   /api/events              # Hook event receiver (from CLI hook subcommands)
GET    /api/health              # Daemon health check
GET    /ws/control?token=...    # Control WebSocket upgrade
GET    /ws/terminal/:id?token=... # Terminal WebSocket upgrade
```

Auth: Bearer token on HTTP, query param on WebSocket upgrade.

## CLI Design

### Distribution
- npm package, usable via `bunx workforce` or `bun install -g workforce`
- Single entry point, subcommands via args

### Commands

```
workforce                          # Launch claude in current dir (default)
workforce <agent> [flags]          # Launch specific agent
workforce list                     # List running agents
workforce attach <id>              # Attach to agent terminal
workforce kill <id>                # Kill agent
workforce daemon start             # Start daemon (auto-done usually)
workforce daemon stop              # Stop daemon
workforce daemon status            # Check daemon status
workforce install                  # Install launchd plist
workforce uninstall                # Remove launchd plist
```

### Terminal Mode (`workforce claude` / `workforce attach`)
1. Ensure daemon is running (start if not)
2. Open control WebSocket, send `spawn` (or just open terminal WS for attach)
3. Open terminal WebSocket for the agent
4. Put local terminal in raw mode
5. Pipe local stdin → WebSocket binary frames → daemon → agent PTY
6. Pipe agent PTY → daemon → WebSocket binary frames → local stdout
7. Send resize on `SIGWINCH`
8. On Ctrl+D or agent exit, detach cleanly

### The `--tmux` / `--zellij` flag
- `workforce claude --tmux` spawns the agent normally via the daemon
- Wraps the `workforce attach` call inside a new tmux/zellij session
- The agent still lives in the daemon's PTY — tmux just wraps the CLI's terminal view for scrollback, detach convenience, etc.

### Hook Integration
- Claude Code hooks still call the `workforce` binary with subcommands (`session-start`, `pre-tool-use`, etc.)
- These subcommands POST to the daemon's HTTP API
- Same JSON stdin parsing as today, different target

## Migration Strategy

### Phase 1: Build the daemon, keep the app working in parallel
- Build the Bun daemon with PTY management, HTTP API, WebSocket
- Rewrite the CLI in Bun to talk to the daemon
- macOS app continues using its own HTTP server and AgentStore
- Both can coexist — daemon manages its own agents, app manages its own

### Phase 2: App becomes thin client
- macOS app drops its HTTP server, AgentStore, and tmux integration
- App connects to the daemon via WebSocket (control + terminal)
- App becomes a pure SwiftUI UI rendering agent state from the daemon
- tmux dependency fully removed

## File Structure (Phase 1)

```
workforce/
├── daemon/
│   ├── index.ts              # Entry point, Bun.serve()
│   ├── pty-manager.ts        # PTY lifecycle, spawn, resize, scrollback
│   ├── agent-store.ts        # Agent state, persistence
│   ├── websocket-hub.ts      # Control + terminal WebSocket management
│   ├── http-api.ts           # REST endpoints
│   ├── auth.ts               # Token generation, validation
│   └── launchd.ts            # Plist generation, install/uninstall
├── cli/
│   ├── index.ts              # Entry point, arg parsing
│   ├── commands/             # Subcommands (spawn, attach, list, kill, daemon, hooks)
│   ├── terminal.ts           # Raw mode, stdin/stdout piping
│   └── daemon-client.ts      # WebSocket + HTTP client to daemon
├── shared/
│   ├── types.ts              # Agent, Event, Message types
│   └── protocol.ts           # WebSocket message schemas
├── package.json
└── bin/
    └── workforce.ts          # CLI bin entry
```
