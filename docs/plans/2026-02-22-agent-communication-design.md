# Inter-Agent Communication Design

> Brainstorm: how should agents in Workforce talk to each other?

## Status Quo

Each agent in Workforce is an island. They run in isolated tmux sessions. Workforce can **observe** them (via hooks → unix socket → app), but agents have **no way to**:

- Send messages to each other
- Request work from another agent
- Share results or artifacts
- Coordinate on a shared task

## The Three Approaches

### Approach 1: File-Based Mailbox (IPC Mailbox)

The simplest option. Each agent gets a mailbox directory. Communication is just files on disk.

```
~/.workforce/mailboxes/
  workforce-1740268800/
    inbox/
      001-from-workforce-1740268801.json
      002-from-workforce-1740268801.json
    outbox/
      001-to-workforce-1740268801.json
```

**How it works:**

- New CLI command: `workforce send <target-session> <message>` writes a JSON file to the target's inbox
- New CLI command: `workforce inbox [session]` reads pending messages
- Agents interact with the mailbox by having Claude Code call `workforce send` / `workforce inbox` via Bash tool calls
- A `workforce instruct <session> <instruction>` command could queue high-priority instructions (like "stop what you're doing and review this file")
- The Workforce app watches mailbox dirs and can show message activity in the UI
- Polling or fsevents to detect new messages

**Pros:**

- Dead simple to implement — it's just files
- Works over SSH with no extra infrastructure
- Agents don't need any new capabilities — they just run bash commands
- Naturally persistent (messages survive restarts)
- Easy to debug (just `cat` the files)

**Cons:**

- Polling-based unless you add fsevents
- No delivery guarantees (agent might not check inbox)
- Agents need to be explicitly instructed to check their inbox or send messages
- Doesn't scale to high-frequency communication

---

### Approach 2: Extend the CLI + Workforce App as Message Broker

Build on the existing unix socket / HTTP architecture. The Workforce app becomes the central message broker.

**How it works:**

- New socket message types: `.sendMessage`, `.receiveMessages`
- New HTTP API endpoints: `POST /api/agents/:id/messages`, `GET /api/agents/:id/messages`
- New CLI commands:
  - `workforce send <target> <message>` — sends via unix socket to the app, which routes to the target
  - `workforce inbox` — queries the app's HTTP API for pending messages
  - `workforce instruct <target> <instruction>` — sends a prioritized instruction
- The app maintains an in-memory message queue per agent, persisted to disk
- Delivery: when a target agent is idle/waiting, Workforce could inject messages via tmux `send-keys` (bold, but effective)

**Pros:**

- Builds on existing architecture — the unix socket and HTTP server are already there
- Centralized routing means the app has full visibility into all inter-agent communication
- Could integrate with the UI (show message flows, conversation threads between agents)
- The app can do smart routing (queue messages for busy agents, prioritize instructions)

**Cons:**

- Requires the Workforce app to be running (breaks SSH-only workflows)
- More complexity in the app
- Still need a way to get agents to actually *read* their messages (the "last mile" problem)

---

### Approach 3: MCP Server

Build an MCP (Model Context Protocol) server that agents connect to. This gives agents native tools for communication.

**How it works:**

- Workforce runs an MCP server (could be bundled with the app or standalone)
- Each Claude Code agent connects to it via MCP config
- The MCP server exposes tools like:
  - `send_message(to: agent_id, message: string)`
  - `read_messages()` — returns pending messages for the calling agent
  - `list_agents()` — see what other agents are running
  - `request_work(description: string)` — ask Workforce to spawn a new agent for a subtask
  - `share_artifact(name: string, content: string)` — share files/results with other agents
- Agent identity resolved via session ID in the MCP connection context

**Pros:**

- Most native integration — tools appear directly in Claude's tool list, no bash indirection
- Claude doesn't need to be told to "run `workforce inbox`" — the tools are just *there*
- Structured input/output (not parsing CLI text)
- MCP is the emerging standard for this kind of thing
- Could expose read-only resources too (other agents' status, shared context)

**Cons:**

- Every agent needs MCP config pointing to the server
- MCP server needs to know agent identity (session correlation)
- More moving parts (MCP server process, stdio/SSE transport)
- MCP is still evolving — transport and auth patterns aren't fully settled
- Doesn't work with non-Claude agents (OpenCode etc.) unless they also support MCP

---

## Hybrid: The Pragmatic Path

In practice, a **layered approach** makes the most sense:

1. **File-based mailbox as the persistence/transport layer** — the "dumb pipe" that works everywhere, over SSH, without the app running. The fallback.

2. **CLI commands (`workforce send`, `workforce inbox`, `workforce instruct`)** — the user-facing and agent-facing interface. These write to the mailbox and optionally notify the app via the existing unix socket.

3. **MCP server as the native integration layer** — for Claude Code agents specifically, the MCP server wraps the same mailbox/CLI primitives but exposes them as native tools. Under the hood, `send_message` MCP tool writes to the mailbox + notifies the app.

4. **Workforce app as the optional coordinator** — when running, it can provide routing, UI visualization, delivery notifications, and smart features (like "inject a message into an idle agent's tmux session").

```
┌─────────────────────────────────────────────────────┐
│                  Claude Code Agent A                 │
│  ┌───────────────┐    ┌────────────────────────┐    │
│  │ MCP tools      │    │ Bash: workforce send   │    │
│  │ send_message() │    │       workforce inbox  │    │
│  └───────┬───────┘    └──────────┬─────────────┘    │
└──────────┼───────────────────────┼──────────────────┘
           │                       │
           ▼                       ▼
┌──────────────────────────────────────────────────┐
│              MCP Server / CLI Layer               │
│                                                   │
│  Reads/writes mailbox files                       │
│  Notifies Workforce app via unix socket           │
└──────────────────┬───────────────────────────────┘
                   │
          ┌────────┴─────────┐
          ▼                  ▼
┌─────────────────┐  ┌──────────────────┐
│  File Mailbox    │  │  Workforce App    │
│  ~/.workforce/   │  │  (optional)       │
│  mailboxes/      │  │  UI, routing,     │
│                  │  │  notifications    │
└─────────────────┘  └──────────────────┘
```

---

## The "Last Mile" Problem

The hardest part of all approaches: **how does an agent know it has a message?**

| Strategy | How it works | Trade-offs |
|----------|-------------|------------|
| **Polling** | Agent periodically runs `workforce inbox` | Wasteful, adds noise to context window |
| **System prompt injection** | Add "check your inbox before starting new work" to agent instructions | Fragile, agents may ignore it |
| **tmux send-keys** | Workforce literally types into the agent's tmux pane | Hacky but effective for idle agents; disruptive for active ones |
| **Claude Code hooks** | A hook fires on `Stop` (idle) and injects mailbox contents | Cleanest for Claude Code, but still requires agent to process injected content |
| **MCP resource subscriptions** | Agent subscribes to inbox changes via MCP | Depends on MCP transport features that may not be mature yet |

The most practical "last mile" for Claude Code specifically: a **hook on the `Stop` event** that checks the mailbox and, if there are pending messages, uses tmux send-keys to inject a prompt like:

```
You have 2 new messages from other agents. Run `workforce inbox` to read them.
```

This bridges the gap between passive mailbox and active notification without requiring MCP subscriptions.

---

## Message Schema (Draft)

```json
{
  "id": "msg-uuid-here",
  "from": "workforce-a1b2c3",
  "to": "workforce-d4e5f6",
  "timestamp": "2026-02-22T18:30:00Z",
  "type": "message",
  "priority": "normal",
  "subject": "Review results for auth module",
  "body": "I've finished implementing the auth module in src/auth/. Can you review the test coverage?",
  "metadata": {
    "cwd": "/path/to/project",
    "artifacts": ["src/auth/handler.swift", "tests/auth_tests.swift"]
  },
  "status": "unread"
}
```

**Message types:**

- `message` — general communication
- `instruction` — high-priority directive (from user or orchestrator agent)
- `work_request` — request to perform a task, with optional acceptance/rejection flow
- `artifact` — sharing a file or result
- `status_update` — "I'm done with X" / "I'm blocked on Y"

---

## Recommendation

**Phase 1: CLI + File Mailbox** ✅

- Implement `workforce send`, `workforce inbox`, `workforce instruct`
- File-based mailbox in `~/.workforce/mailboxes/`
- New socket message type `.agentMessage` so the app can visualize messages
- Hook-based "you have mail" notification on agent idle (StopCommand)

**Phase 2: MCP Server** ✅

- `workforce mcp-serve` — JSON-RPC 2.0 stdio MCP server
- Exposes `send_message`, `read_messages`, `list_agents` as native MCP tools
- Auto-configured via `workforce install-hooks` (adds `mcpServers.workforce` to settings)
- Session identity resolved from `WORKFORCE_SESSION` env var

**Phase 3: Orchestration**

- `workforce instruct` with tmux send-keys delivery for idle agents
- "Agent of agents" pattern: one orchestrator delegates to workers
- UI: message timeline view, inter-agent conversation threads
- Smart routing: app queues messages for busy agents, delivers when idle
