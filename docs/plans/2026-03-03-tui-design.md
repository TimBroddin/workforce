# TUI Package Design

**Date**: 2026-03-03
**Package**: `packages/tui`

## Overview

A terminal-based UI for Workforce that provides tmux-like tab switching between agent terminal sessions. Complements the desktop app for users who prefer staying in the terminal.

## Tech Stack

- **Ink** (React for CLI) — layout, sidebar, focus management
- **@xterm/headless** — virtual terminal emulation per agent (buffer management, ANSI parsing)
- **WebSocket** — connects to running daemon for control events + PTY data

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                     Terminal                         │
│  ┌────────────────┐ ┌────────────────────────────┐  │
│  │    Sidebar     │ │   Terminal Viewport         │  │
│  │                │ │                             │  │
│  │ ~/Projects/app │ │  (rendered from             │  │
│  │  ● Finn       │ │   @xterm/headless buffer    │  │
│  │  ◐ Jake       │ │   of selected agent)        │  │
│  │  [+] New      │ │                             │  │
│  │                │ │                             │  │
│  │ ~/Projects/api │ │                             │  │
│  │  ● BMO        │ │                             │  │
│  │  [+] New      │ │                             │  │
│  │                │ │                             │  │
│  └────────────────┘ └────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Daemon Dependency

Requires a running agenthub daemon. The TUI connects via:

- `GET /api/agents` — initial agent list
- `WS /ws/control` — real-time agent lifecycle events (register, deregister, status changes)
- `WS /ws/terminal/:id` — PTY I/O per agent (binary frames for terminal data, JSON for resize)

## Sidebar

### Grouping

Agents grouped by `cwd` (working directory). Folder labels show shortened paths with `~` replacing `$HOME`.

### Agent Display

Each agent shows:
- Status icon: `●` active, `◐` waiting for input/permission, `○` idle, `✕` stopped
- Agent name (from daemon's name generator)

### Actions

- `[+] New` button under each folder group — spawns a new agent with that folder as `cwd`
- Spawn defaults to `claude` agent type

## Terminal Viewport

### Rendering Pipeline

```
WS /ws/terminal/:id
    │ (binary PTY data)
    ▼
@xterm/headless Terminal instance
    │ (virtual screen buffer)
    ▼
Buffer → Ink <Text> conversion
    │ (extract visible rows, map ANSI attrs to Ink colors)
    ▼
Ink <Box> render
```

Each agent gets:
1. A WebSocket connection to `/ws/terminal/:id` (opened lazily on first select)
2. An `@xterm/headless` Terminal instance fed by that WebSocket
3. The active agent's xterm buffer is rendered into the Ink viewport on each update

### Resize Handling

Terminal viewport dimensions calculated from Ink's layout (total cols minus sidebar width). Resize events sent to daemon via the terminal WebSocket as `{ type: "resize", cols, rows }`.

## Focus Model

**Tab** toggles focus between sidebar and terminal pane.

### Sidebar Focused

| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate between agents |
| `Enter` | Select agent (switch terminal viewport) |
| `c` | Spawn new agent in currently highlighted folder |
| `k` | Kill highlighted agent |
| `q` | Quit TUI (agents keep running) |

### Terminal Focused

All keystrokes forwarded to the active agent's PTY via WebSocket binary frames.

### Visual Focus Indicator

Active pane indicated by border color or highlight change on the sidebar.

## CLI Integration

New command: `agenthub tui`

Launched from `packages/cli/src/index.ts` — imports and renders the Ink app from `packages/tui`.

## Package Structure

```
packages/tui/
├── package.json
├── src/
│   ├── index.tsx           # Entry point, Ink render()
│   ├── App.tsx             # Root component, focus state, daemon connection
│   ├── components/
│   │   ├── Sidebar.tsx     # Agent list grouped by folder
│   │   ├── FolderGroup.tsx # Single folder with its agents + [+] New
│   │   ├── AgentRow.tsx    # Agent name + status icon
│   │   └── Terminal.tsx    # xterm/headless buffer → Ink renderer
│   ├── hooks/
│   │   ├── useDaemon.ts    # Control WebSocket + agent list state
│   │   ├── useTerminal.ts  # Terminal WebSocket + xterm/headless per agent
│   │   └── useFocus.ts     # Tab-based focus management
│   └── lib/
│       ├── xterm-ink.ts    # Convert xterm buffer rows to Ink Text elements
│       └── path-utils.ts   # Home dir shortening, grouping logic
```

## Dependencies

- `ink` — React CLI framework
- `react` — Peer dependency for Ink
- `@xterm/headless` — Virtual terminal emulation
- `ws` or native WebSocket — Daemon communication
- `@workforce/shared` — Shared types (Agent, SocketMessage, etc.)

## Decisions

- **Daemon required**: No standalone mode. Keeps TUI simple — it's a view layer only.
- **Lazy terminal connections**: WebSocket to `/ws/terminal/:id` opened on first select, not on agent discovery. Saves resources.
- **@xterm/headless for rendering**: Handles all ANSI complexity (cursor movement, colors, screen clearing, scrollback) that raw text accumulation cannot.
- **Tab for focus toggle**: Simple, no prefix key complexity. The daemon's WebSocket intercepts before the agent sees keystrokes.
- **Ink for UI**: React component model, flexbox layout, good ecosystem. Matches user preference.
