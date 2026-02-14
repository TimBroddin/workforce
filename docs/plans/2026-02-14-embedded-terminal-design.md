# Embedded Terminal with SwiftTerm + tmux

**Date:** 2026-02-14
**Epic:** bd-os1
**Status:** Approved

## Summary

Add an embedded terminal to the Workforce app using SwiftTerm. Users launch Claude via `workforce run` which wraps it in a tmux session. The menu bar icon opens a main window with tabs per working directory, a sidebar with agent list, and a terminal pane attached to the selected agent's tmux session. Replaces the current menu bar popover.

## Architecture

### `workforce run` CLI command

```
workforce run [-- claude-args...]
```

1. Generates session name: `workforce-<6-char-hex>` (e.g., `workforce-a3f9b2`)
2. Checks tmux is in PATH (errors with install instructions if not)
3. Runs: `tmux new-session -s workforce-<id> -- claude [claude-args...]`
4. Foreground — user's terminal becomes the tmux session
5. When Claude exits, the tmux session ends naturally

The existing hook system fires normally inside the tmux session. The SessionStart hook detects `$TMUX`, extracts the session name, and includes it as `tmuxSession` in the registration message.

### Model changes

`Agent` gains: `tmuxSession: String?`
`SocketMessage` gains: `tmuxSession: String?`

Agents without a `tmuxSession` (started outside `workforce run`) still appear in the sidebar but show a "No terminal available — started outside workforce run" placeholder instead of a terminal.

### Main window layout

```
┌──────────────────────────────────────────────────┐
│  [~/Projects/workforce] [~/Projects/other]        │  tab bar (one per unique cwd)
├──────────────┬───────────────────────────────────┤
│  Agent List  │                                   │
│  ───────────  │                                   │
│  ● Agent A   │       SwiftTerm Terminal          │
│    Opus      │       (tmux attach -t ...)        │
│  ○ Agent B   │                                   │
│    Sonnet    │                                   │
│              │                                   │
├──────────────┴───────────────────────────────────┤
│  3 agents                                   Quit │
└──────────────────────────────────────────────────┘
```

- **Tab bar:** One tab per unique `cwd`. Shows abbreviated path. Auto-creates when a new cwd appears, auto-removes when last agent in that cwd deregisters.
- **Sidebar:** Agent list filtered to selected tab's cwd. Reuses `AgentRowView` styling (avatar, name, status badge, model, current tool).
- **Terminal pane:** SwiftTerm `LocalProcessTerminalView` running `tmux attach -t <session>`. Swaps on agent selection.
- **Menu bar icon:** Click opens/focuses main window instead of popover. Status coloring (red/orange) remains.

### SwiftTerm integration

- SPM dependency: `migueldeicaza/SwiftTerm` (v1.10.x)
- `TerminalRepresentable: NSViewRepresentable` wrapping `LocalProcessTerminalView`
- On agent select: `startProcess(executable: "/usr/bin/tmux", args: ["attach", "-t", sessionName])`
- On agent switch: terminate current process, start new attach
- On agent deregister: show "Session ended" placeholder
- No app sandbox (already the case) — required for `forkpty()`

## Dependency graph

```
bd-os1.1: SwiftTerm SPM dependency ─────────────────┐
bd-os1.2: workforce run CLI command                  │
     │                                               │
     ▼                                               │
bd-os1.3: tmux session in hook message               │
     │                                               ▼
     │                    bd-os1.4: Replace popover with main window
     │                         │
     │                         ▼
     │                    bd-os1.5: Tabbed sidebar by cwd
     │                         │
     ▼                         │
bd-os1.6: SwiftTerm view ──────┤
                               │
                               ▼
                    bd-os1.7: Wire agent selection to terminal
                               │
                               ▼
                    bd-os1.8: End-to-end test
```

Parallelizable work streams:
- **Stream A:** os1.1 (SwiftTerm dep) + os1.4 (main window) + os1.5 (tabbed sidebar)
- **Stream B:** os1.2 (workforce run) + os1.3 (hook message)
- **Merge:** os1.6 (SwiftTerm view, needs A+B) → os1.7 (wiring) → os1.8 (test)

## Decisions

- **tmux required:** Users must have tmux installed. `workforce run` checks and provides install instructions.
- **No process management:** App only attaches to tmux sessions, never spawns Claude directly.
- **Tab = cwd:** Tabs are grouped by working directory, not by session or host app.
- **Graceful degradation:** Agents started outside `workforce run` (no tmux session) show in sidebar with a placeholder in the terminal pane.
