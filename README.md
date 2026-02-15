# Workforce

> ⚠️ **SUPER EXPERIMENTAL & BUGGY ATM** ⚠️ — Workforce is under active development. Expect rough edges and breaking changes.

Stop losing track of your AI coding agents. Workforce is a native macOS app that uses some tmux magic under to hood to keep all your agent sessions visible and manageable in one place.

Built with deep integration for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) via its hook system, with basic support for other agents.

![Workforce screenshot](screenshot.png)

## Features

- **Agent Dashboard** — See all running agents at a glance with live status indicators (active, idle, waiting for input/permission)
- **Embedded Terminals** — View agent terminal sessions directly in the app via xterm.js
- **Notifications** — Get macOS alerts when agents need interaction
- **Event Viewer** — Debug hook messages with a real-time event log and type filtering
- **Tmux Integration** — Agents run in tmux sessions that persist independently of the app
- **Agent Management** — Spawn new agents, kill sessions, open in your preferred terminal or IDE

## Requirements

- macOS 15.0 (Sequoia) or later
- [tmux](https://github.com/tmux/tmux)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (for full hook integration)

## Installation

Grab the latest release from the [Releases](https://github.com/timbroddin/workforce/releases) page.

## Usage

1. Launch the Workforce app — the first-run wizard will guide you through installing the CLI binary and Claude Code hooks
2. Use `workforce run` to start agents — they'll appear in the dashboard automatically
3. Monitor agent status, view terminals, and receive notifications when agents need input

### CLI Commands

```sh
workforce run [prompt]              # Launch Claude Code in tmux (default)
workforce run --agent codex [prompt] # Launch a different agent (codex, opencode, ...)
workforce install-hooks      # Register hooks in Claude Code settings
workforce uninstall-hooks    # Remove hooks from Claude Code settings
```

## How It Works

Workforce wraps each agent session in a tmux session, making them discoverable and persistent. A Unix socket (`/tmp/workforce-<uid>.sock`) handles IPC between the CLI and the app — when Claude Code triggers a hook, the `workforce` CLI forwards the event over the socket, and the app updates the UI in real-time.

## Project Structure

```
Workforce/          macOS SwiftUI application
WorkforceKit/       Swift package containing:
  WorkforceKit      Shared models and utilities
  WorkforceCLI      CLI binary (workforce command) used by Claude Code hooks
```

## License

MIT
