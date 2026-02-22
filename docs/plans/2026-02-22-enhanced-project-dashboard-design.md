# Enhanced Project Dashboard — Design Document

**Date**: 2026-02-22
**Status**: Draft

## Problem

Workforce already groups agents by project folder in the sidebar. But when managing multiple agents across projects, there's no visibility into:

1. **What each project/agent is costing** — no token usage or cost tracking
2. **Git state of the project** — no branch info, dirty files, or conflict warnings
3. **Project-level activity** — the right pane only shows a terminal; there's no aggregate view

## Goal

Add a **project detail panel** and **token/cost tracking** to give users a birds-eye view of each project without leaving the app.

## Design

### 1. Token & Cost Tracking

#### Data source

Claude Code hook events do **not** include token usage directly. However, every hook event includes a `transcript_path` field pointing to a JSONL file that contains per-turn usage data:

```json
{
  "message": {
    "role": "assistant",
    "usage": {
      "input_tokens": 1234,
      "output_tokens": 567,
      "cache_creation_input_tokens": 100,
      "cache_read_input_tokens": 200
    }
  }
}
```

**Approach**: On `Stop` and `SessionEnd` hook events, the CLI reads the transcript file and sums token usage, then sends the totals to the app via the socket. This avoids continuous file watching and keeps the CLI fast (transcript parsing only happens at natural pause points).

Additionally, we add a new `Stop` hook handler to the CLI to capture the transcript path and parse usage at the end of each agent turn.

#### Data model changes

**SocketMessage** — add optional token fields:

```swift
public var inputTokens: Int?
public var outputTokens: Int?
public var cacheCreationTokens: Int?
public var cacheReadTokens: Int?
```

**Agent** — add accumulated token fields:

```swift
public var totalInputTokens: Int = 0
public var totalOutputTokens: Int = 0
public var totalCacheCreationTokens: Int = 0
public var totalCacheReadTokens: Int = 0
```

**New: `SocketMessageType.updateTokens`** — a dedicated message type for token updates.

#### Cost estimation

Estimated cost is computed in the app using known API pricing per model. Store a simple lookup table mapping model names to per-token rates. Display as `$X.XX` on the UI. The model name is already available on the Agent (sent during registration).

#### Persistence

Token data is stored in a JSON file per project folder in `~/Library/Application Support/Workforce/tokens/`. Structure:

```json
{
  "projectPath": "/Users/tim/Projects/workforce",
  "sessions": [
    {
      "sessionId": "abc123",
      "model": "claude-sonnet-4-6",
      "startedAt": "2026-02-22T10:00:00Z",
      "inputTokens": 50000,
      "outputTokens": 12000,
      "cacheCreationTokens": 1000,
      "cacheReadTokens": 5000,
      "estimatedCostUSD": 0.42
    }
  ]
}
```

Flushed to disk whenever token data is updated. Loaded on app launch.

### 2. Project Detail Panel

When a user clicks a **folder header** (not an agent row), the right pane switches from the terminal view to a **project detail view** with three tab sections:

#### Tab 1: Stats

- **Total tokens** (input + output) across all agents in this project
- **Estimated cost** (USD) for the project, summed across agents
- **Active sessions** count
- **Per-agent breakdown** table: agent name, model, tokens, cost, duration

#### Tab 2: Git

All data fetched by running git commands against the project folder (polling every 15–30 seconds):

- **Current branch** — read from `.git/HEAD`
- **Dirty file count** — from `git status --porcelain`
- **Recent commits** (last 10) — from `git log --oneline -10`
- **Branches with active agents** — cross-reference agent branch data
- **Conflict warning** — highlight if 2+ agents are on the same branch

#### Tab 3: Activity

- Merged chronological feed of all hook events from agents in this project
- Reuses the existing `EventLog` entries, filtered by project `cwd`
- Shows: timestamp, agent name, event type, tool name/details
- Capped at last 100 entries per project

### 3. UI Changes

#### Sidebar (minimal changes)

- **Agent row**: append a subtle cost label after the status dot: `$0.42`
- **Folder header**: append a small aggregate cost badge: `$1.23`
- No other sidebar layout changes

#### Right pane (selection-aware)

The right pane now responds to two selection types:

1. **Agent selected** (existing behavior): show embedded terminal
2. **Folder selected** (new): show project detail panel with Stats/Git/Activity tabs

Selection logic:
- Clicking a folder header toggles collapse (existing) — but we add a way to *select* the folder (e.g., clicking the folder name/icon area selects it, clicking the chevron toggles collapse)
- Or: add a small info button on the folder header that opens the project detail panel
- When no agent is selected and a folder is, show the detail panel

#### Footer

- Update footer to show aggregate cost: `3 agents · $2.15 today`

### 4. CLI Changes

#### New hook: `Stop`

Add a `StopCommand` that:
1. Reads the `transcript_path` from the hook JSON
2. Parses the JSONL file to extract all `usage` objects
3. Sums tokens by type
4. Sends a `SocketMessage(type: .updateTokens)` with the totals

This fires at natural pause points (every time Claude finishes a response), providing near-real-time cost tracking without polling files.

#### Updated hook: `SessionEnd`

Also parse and send final token totals on session end, to ensure we capture the complete session cost even if the Stop hook was missed.

#### Hook installation

`install-hooks` needs to register the new `Stop` hook in `~/.claude/settings.json`.

### 5. What's NOT in scope

- Per-file change tracking (which files each agent modified)
- Agent orchestration (spawning fleets with coordinated tasks)
- Historical data across days/weeks (just current session data + persisted totals)
- Network/SSH agent support

## Architecture Summary

```
Claude Code "Stop" hook
  → workforce stop (CLI)
  → reads transcript_path JSONL, sums tokens
  → sends SocketMessage(.updateTokens) via socket
  → AgentStore updates Agent.totalInputTokens etc.
  → UI updates: agent row cost label, project detail panel stats
  → TokenStore flushes to disk

Folder click in sidebar
  → selectedFolderId set (new state)
  → right pane switches to ProjectDetailView
  → Stats tab reads from AgentStore + TokenStore
  → Git tab polls git commands against cwd
  → Activity tab filters EventLog by cwd
```

## Open Questions

1. **Folder selection UX**: Should clicking the folder name select it (and show the detail panel), with the chevron toggling collapse? Or should there be a separate info/detail button?
2. **Cost persistence granularity**: Should we track daily totals, or just per-session?
3. **Git polling frequency**: 15s feels right — too fast wastes CPU, too slow feels stale. Configurable?
