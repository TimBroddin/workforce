# AgentHub Phase 1b: Monorepo, Hooks, Tokens, Resilience

**Date:** 2026-03-01
**Status:** Design approved

## Overview

Four changes to make the Bun daemon production-ready:

1. **Monorepo restructure** — rename to `agenthub`, split into `packages/daemon`, `packages/cli`, `packages/shared`, `packages/desktop`
2. **Hook installation** — `agenthub install-hooks` writes Claude Code hooks to `~/.claude/settings.json`
3. **Token tracking** — parse transcript JSONL on session-end to extract token usage
4. **Daemon resilience** — re-adopt orphaned agent processes on daemon restart

## 1. Monorepo Structure

```
workforce/  (git repo stays named workforce)
├── packages/
│   ├── shared/                  # Shared types + utilities
│   │   ├── src/
│   │   │   ├── types.ts
│   │   │   └── transcript.ts    # Token parsing
│   │   └── package.json         # name: "shared" (internal)
│   ├── daemon/                  # Bun daemon server
│   │   ├── src/
│   │   │   ├── index.ts
│   │   │   ├── auth.ts
│   │   │   ├── agent-store.ts
│   │   │   ├── pty-manager.ts
│   │   │   └── websocket-hub.ts
│   │   ├── test/
│   │   │   ├── auth.test.ts
│   │   │   ├── agent-store.test.ts
│   │   │   ├── pty-manager.test.ts
│   │   │   └── websocket-hub.test.ts
│   │   └── package.json         # name: "daemon" (internal)
│   ├── cli/                     # Bun CLI client
│   │   ├── src/
│   │   │   ├── index.ts         # #!/usr/bin/env bun
│   │   │   ├── daemon-client.ts
│   │   │   ├── terminal.ts
│   │   │   └── hooks.ts         # install/uninstall hooks
│   │   ├── test/
│   │   │   └── integration.test.ts
│   │   └── package.json         # name: "agenthub", bin: { agenthub: "./src/index.ts" }
│   └── desktop/                 # Swift macOS app (moved from root)
│       ├── Workforce/           # SwiftUI app
│       ├── WorkforceKit/        # Swift package + CLI
│       └── ...
├── package.json                 # Root workspace
├── tsconfig.json                # Root TS config
└── docs/
```

### Package configuration

Root `package.json`:
```json
{
  "private": true,
  "workspaces": ["packages/shared", "packages/daemon", "packages/cli"]
}
```

Packages use relative path imports within the workspace. Only `agenthub` (the CLI) is published to npm.

### Config directory

`~/.agenthub/` replaces `~/.workforce/`:
- `daemon.pid`, `daemon.port`, `daemon.token`
- `agents.json`
- `daemon.stdout.log`, `daemon.stderr.log`

Environment variable: `AGENTHUB_SESSION` replaces `WORKFORCE_SESSION`.

Launchd label: `com.agenthub.daemon`.

## 2. Hook Installation

### `agenthub install-hooks`

Writes to `~/.claude/settings.json`, merging with existing content. All 9 Claude Code hook events:

```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<binary-path> session-start" }] }],
    "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<binary-path> pre-tool-use" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<binary-path> post-tool-use" }] }],
    "PostToolUseFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<binary-path> post-tool-use-failure" }] }],
    "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<binary-path> notification" }] }],
    "SubagentStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<binary-path> subagent-start" }] }],
    "SubagentStop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<binary-path> subagent-stop" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<binary-path> stop" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<binary-path> session-end" }] }]
  }
}
```

Binary path resolved via `process.argv[0]` or `Bun.which("agenthub")`.

### `agenthub uninstall-hooks`

Reads `~/.claude/settings.json`, removes only entries whose command contains `agenthub`, preserves all other hooks. Writes back.

## 3. Token Tracking

### Transcript format

Claude Code writes JSONL transcript files. Each line:
```json
{"type":"assistant","message":{"role":"assistant","content":"...","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":20}}}
```

### Parser

`packages/shared/src/transcript.ts` exports:

```typescript
interface TokenSummary {
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
}

function parseTranscriptTokens(filePath: string): Promise<TokenSummary>
```

Reads file line by line, extracts `message.usage.*` fields, sums them. Returns zeros if file doesn't exist or is empty.

### Integration

The `session-end` hook handler changes from:
1. Send `deregister`

To:
1. If `transcript_path` exists, parse tokens → send `updateTokens` event
2. Send `deregister`

## 4. Daemon Resilience

### On daemon startup

After loading `agents.json`:

1. For each persisted agent, check if `pid` is still alive (`process.kill(pid, 0)`)
2. If alive → mark as `status: "orphaned"` — visible in `agenthub list`, killable via `agenthub kill`, but not attachable (we can't re-adopt a PTY we didn't create)
3. If dead → remove from store

### Agent metadata changes

The `Agent` interface gains a `pid` field:
```typescript
interface Agent {
  // ... existing fields
  pid?: number;  // child process PID, set on spawn
}
```

The PTY manager sets `pid` from `proc.pid` after spawn. The agent store includes `pid` in persistence.

### Orphaned agent handling

Orphaned agents show in `agenthub list` with status `orphaned`. Users can:
- `agenthub kill <id>` — sends SIGTERM to the PID
- Wait for the process to exit naturally

Orphaned agents cannot be attached to (the PTY handle is lost). This is a pragmatic limitation — the correct fix is for the daemon to not die in the first place (launchd `KeepAlive: true` handles this).
