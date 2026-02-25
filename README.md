# Workforce

> **SUPER EXPERIMENTAL & BUGGY ATM** — Workforce is under active development. Expect rough edges and breaking changes.

Stop losing track of your AI coding agents. Workforce is a native macOS app that keeps all your agent sessions visible and manageable in one place — whether they're running locally or on a remote machine over SSH.

Built with deep integration for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) hooks and [OpenCode](https://opencode.ai/) plugins.

![Workforce screenshot](screenshot.png)

## Features

- **Agent Dashboard** — See all running agents at a glance with live status indicators (active, idle, waiting for input/permission)
- **Embedded Terminals** — View agent terminal sessions directly in the app via xterm.js
- **Smart Notifications** — Get macOS alerts when agents need input, with optional AI-generated transcript summaries (via Apple Intelligence or OpenRouter, or disabled entirely)
- **Cost Tracking** — Monitor token usage and estimated costs per agent, per project folder, and across all sessions
- **Project Detail View** — Drill into projects with stats, git info, and recent activity
- **Event Viewer** — Debug hook messages with a real-time event log and type filtering
- **Tmux Integration** — Agents run in tmux sessions that persist independently of the app
- **Agent Management** — Spawn new agents, kill sessions, open in your preferred terminal or IDE
- **Remote Hosts** — Connect to remote machines over SSH with collapsible folder views, per-folder agent spawning, and full remote agent management via the HTTP API
- **Connected Clients** — See which clients are connected to your workforce instance
- **CLI Tools** — List agents, attach to sessions, and browse with an interactive TUI — works over SSH too

## How It Works

```
┌──────────────────────────────────────────────────────────────────┐
│                      Workforce macOS App                         │
│  ┌──────────┐  ┌──────────────┐  ┌────────────────────────────┐  │
│  │ Agent    │  │ Notification │  │ HTTP API Server            │  │
│  │ Store    │  │ Manager      │  │ GET    /api/agents         │  │
│  │          │  │ + Summarizer │  │ GET    /api/agents/:id     │  │
│  │          │  │              │  │ POST   /api/spawn          │  │
│  │          │  │              │  │ DELETE /api/agents/:id     │  │
│  │          │  │              │  │ POST   /api/events         │  │
│  │          │  │              │  │ POST   /api/clients/register│  │
│  │          │  │              │  │ GET    /api/clients        │  │
│  └────▲─────┘  └──────────────┘  └──────────────▲─────────────┘  │
│       │                                         │                │
│       │  Unix Socket                            │  HTTP          │
│       │  /tmp/workforce-<uid>.sock              │  localhost     │
└───────┼─────────────────────────────────────────┼────────────────┘
        │                                         │
  ┌─────┴─────────────┐              ┌────────────┴────────────┐
  │ workforce CLI      │              │ workforce list          │
  │ (hook handler)     │              │ workforce attach        │
  │                    │              │ workforce tui           │
  │ Receives events    │              │                         │
  │ from Claude Code   │              │ Queries agent state,    │
  │ via stdin JSON     │              │ spawns & deletes agents │
  └────────▲───────────┘              └────────────────────────┘
           │
  ┌────────┴───────────┐
  │ Claude Code /      │
  │ OpenCode           │
  │                    │
  │ Fires hooks on:    │
  │ • session start    │
  │ • tool use         │
  │ • notifications    │
  │ • subagent events  │
  │ • session end      │
  └────────────────────┘
```

When you run an agent with `workforce`, it wraps the session in tmux for persistence. Claude Code hooks fire events (tool use, status changes, notifications) as JSON to the `workforce` CLI, which forwards them over a Unix socket to the app. The app updates the dashboard in real-time and sends macOS notifications when agents need your attention.

The app also runs a lightweight HTTP API on localhost, which the CLI uses to query agent state for `list`, `attach`, and `tui` commands. Remote agents are spawned and deleted through the same API via SSH tunnels.

## Requirements

- macOS 14.6 (Sonoma) or later
- [tmux](https://github.com/tmux/tmux)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [OpenCode](https://opencode.ai/) (for full event integration)

## Installation

### Homebrew

```sh
brew install --cask timbroddin/tap/workforce
```

### Download

Grab the latest release from the [Releases](https://github.com/timbroddin/workforce/releases) page.

## Usage

1. Launch the Workforce app — the first-run wizard will guide you through installing the CLI binary and Claude Code hooks
2. Use `workforce` to start agents — they'll appear in the dashboard automatically
3. Monitor agent status, view terminals, and receive notifications when agents need input

### CLI Commands

```sh
# Agent management
workforce                             # Launch Claude Code in tmux (default)
workforce --agent codex               # Launch a different agent (codex, opencode, ...)

# Query & interact
workforce list                        # List all active agent sessions
workforce list --json                 # Output as JSON
workforce attach <session>            # Attach to an agent's tmux session
workforce tui                         # Interactive session picker (ncurses)

# Hook management
workforce install-hooks               # Register Claude hooks + OpenCode plugin
workforce uninstall-hooks             # Remove Claude hooks + OpenCode plugin
```

#### `workforce list`

Shows a table of all active sessions with their status, agent type, working directory, and display title. Queries the app's HTTP API first, falling back to tmux session discovery if the app isn't running.

#### `workforce attach <session>`

Attaches your terminal to an agent's tmux session. Accepts a full session name, partial ID, or suffix match — e.g. `workforce attach a1b2c3` will match `workforce-a1b2c3`.

#### `workforce tui`

An interactive ncurses-based session picker. Navigate with arrow keys, press Enter to attach, `r` to refresh, `q` to quit. Auto-refreshes every 3 seconds.

## Remote Agents over SSH

One of the most useful things about Workforce's CLI tools is that they work over SSH. If you have agents running on a remote machine (a dev server, a cloud VM, a headless build box), you can manage them from anywhere:

```sh
# SSH into your remote machine
ssh devbox

# See what's running
workforce list

# Attach to an agent that needs input
workforce attach workforce-1740268800

# Or use the interactive picker
workforce tui
```

Since agents run in tmux sessions, they persist across SSH disconnections. You can start agents on a remote machine, disconnect, and reconnect later to check on them — your sessions will still be there.

This makes Workforce great for:
- **Remote dev servers** — Start agents on a powerful remote machine, check in from your laptop
- **Headless CI/build boxes** — Monitor long-running agent tasks without keeping a terminal open
- **Pair programming** — Multiple people can attach to the same agent session

## Notification Summaries

When an agent needs your input, Workforce can generate a short summary of what the agent has been working on, so you know the context before switching to it.

The notification shows Claude's message as the title, with an AI-generated transcript summary as the body. You can choose between summarization backends in Settings:

- **Disabled** — No AI summaries, just the agent title in the notification body
- **Apple Intelligence** — Uses the on-device Foundation Models framework (requires macOS 26+ and Apple Intelligence enabled)
- **OpenRouter** — Uses any model via the OpenRouter API (default: `google/gemini-2.5-flash-lite`)

## Project Structure

```
Workforce/          macOS SwiftUI application
WorkforceKit/       Swift package containing:
  WorkforceKit      Shared models and utilities
  WorkforceCLI      CLI binary (workforce command) used by Claude Code hooks
```

## License

MIT
