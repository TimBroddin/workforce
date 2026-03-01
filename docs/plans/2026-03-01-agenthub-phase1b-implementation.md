# AgentHub Phase 1b Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restructure into a monorepo named `agenthub`, add hook installation, transcript token tracking, and daemon resilience.

**Architecture:** Move existing `daemon/` code into `packages/{shared,daemon,cli}` with Bun workspaces. Add transcript parser to shared, hook installer to CLI, orphan re-adoption to daemon. Rename all `workforce` references to `agenthub`.

**Tech Stack:** Bun workspaces, TypeScript

**Design doc:** `docs/plans/2026-03-01-agenthub-phase1b-design.md`

---

## Task 1: Monorepo restructure — move files

This task moves existing code into the `packages/` structure. No code changes yet, just file moves.

**Files:**
- Move: `daemon/shared/types.ts` → `packages/shared/src/types.ts`
- Move: `daemon/daemon/auth.ts` → `packages/daemon/src/auth.ts`
- Move: `daemon/daemon/auth.test.ts` → `packages/daemon/test/auth.test.ts`
- Move: `daemon/daemon/agent-store.ts` → `packages/daemon/src/agent-store.ts`
- Move: `daemon/daemon/agent-store.test.ts` → `packages/daemon/test/agent-store.test.ts`
- Move: `daemon/daemon/pty-manager.ts` → `packages/daemon/src/pty-manager.ts`
- Move: `daemon/daemon/pty-manager.test.ts` → `packages/daemon/test/pty-manager.test.ts`
- Move: `daemon/daemon/websocket-hub.ts` → `packages/daemon/src/websocket-hub.ts`
- Move: `daemon/daemon/websocket-hub.test.ts` → `packages/daemon/test/websocket-hub.test.ts`
- Move: `daemon/daemon/index.ts` → `packages/daemon/src/index.ts`
- Move: `daemon/cli/daemon-client.ts` → `packages/cli/src/daemon-client.ts`
- Move: `daemon/cli/terminal.ts` → `packages/cli/src/terminal.ts`
- Move: `daemon/cli/index.ts` → `packages/cli/src/index.ts`
- Move: `daemon/test/integration.test.ts` → `packages/cli/test/integration.test.ts`
- Move: `Workforce/` → `packages/desktop/Workforce/`
- Move: `WorkforceKit/` → `packages/desktop/WorkforceKit/`
- Delete: `daemon/` directory (after moves)
- Create: root `package.json`, `tsconfig.json`
- Create: `packages/shared/package.json`
- Create: `packages/daemon/package.json`
- Create: `packages/cli/package.json`

**Step 1: Create directory structure and move files**

```bash
# Create new structure
mkdir -p packages/shared/src packages/daemon/src packages/daemon/test packages/cli/src packages/cli/test packages/desktop

# Move shared
mv daemon/shared/types.ts packages/shared/src/types.ts

# Move daemon
mv daemon/daemon/auth.ts packages/daemon/src/auth.ts
mv daemon/daemon/auth.test.ts packages/daemon/test/auth.test.ts
mv daemon/daemon/agent-store.ts packages/daemon/src/agent-store.ts
mv daemon/daemon/agent-store.test.ts packages/daemon/test/agent-store.test.ts
mv daemon/daemon/pty-manager.ts packages/daemon/src/pty-manager.ts
mv daemon/daemon/pty-manager.test.ts packages/daemon/test/pty-manager.test.ts
mv daemon/daemon/websocket-hub.ts packages/daemon/src/websocket-hub.ts
mv daemon/daemon/websocket-hub.test.ts packages/daemon/test/websocket-hub.test.ts
mv daemon/daemon/index.ts packages/daemon/src/index.ts

# Move CLI
mv daemon/cli/daemon-client.ts packages/cli/src/daemon-client.ts
mv daemon/cli/terminal.ts packages/cli/src/terminal.ts
mv daemon/cli/index.ts packages/cli/src/index.ts
mv daemon/test/integration.test.ts packages/cli/test/integration.test.ts

# Move desktop (Swift)
mv Workforce packages/desktop/Workforce
mv WorkforceKit packages/desktop/WorkforceKit

# Remove old daemon directory
rm -rf daemon
```

**Step 2: Create root package.json**

```json
{
  "private": true,
  "workspaces": ["packages/shared", "packages/daemon", "packages/cli"],
  "scripts": {
    "test": "bun test packages/",
    "test:unit": "bun test packages/daemon/test/",
    "test:integration": "bun test packages/cli/test/ --timeout 15000",
    "daemon": "bun run packages/daemon/src/index.ts"
  }
}
```

Save to `/Users/timbroddin/Projects/workforce/package.json`.

**Step 3: Create root tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "types": ["bun-types"],
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  }
}
```

Save to `/Users/timbroddin/Projects/workforce/tsconfig.json`.

**Step 4: Create packages/shared/package.json**

```json
{
  "name": "shared",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "exports": {
    ".": "./src/types.ts",
    "./transcript": "./src/transcript.ts"
  }
}
```

**Step 5: Create packages/daemon/package.json**

```json
{
  "name": "daemon",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "dependencies": {
    "shared": "workspace:*"
  },
  "scripts": {
    "start": "bun run src/index.ts",
    "test": "bun test test/"
  }
}
```

**Step 6: Create packages/cli/package.json**

```json
{
  "name": "agenthub",
  "version": "0.1.0",
  "type": "module",
  "bin": {
    "agenthub": "./src/index.ts"
  },
  "dependencies": {
    "shared": "workspace:*"
  },
  "scripts": {
    "test": "bun test test/ --timeout 15000"
  },
  "files": ["src/"],
  "engines": {
    "bun": ">=1.3.5"
  },
  "keywords": ["ai", "agent", "terminal", "pty", "claude"],
  "license": "MIT"
}
```

**Step 7: Delete old daemon package files**

```bash
rm -f daemon/package.json daemon/tsconfig.json
```

**Step 8: Commit**

```bash
git add -A
git commit -m "refactor: restructure into monorepo with packages/{shared,daemon,cli,desktop}"
```

---

## Task 2: Fix imports for new paths

After the file move, all relative imports are broken. Fix them.

**Files:**
- Modify: `packages/daemon/src/agent-store.ts` — change `../shared/types` → `shared`
- Modify: `packages/daemon/src/index.ts` — change `../shared/types` → `shared`, change `./auth` etc (these should still work as `./auth`)
- Modify: `packages/daemon/src/websocket-hub.ts` — change `../shared/types` → `shared`
- Modify: `packages/daemon/test/agent-store.test.ts` — change `../shared/types` → `shared`, change `./agent-store` → `../src/agent-store`
- Modify: `packages/daemon/test/auth.test.ts` — change `./auth` → `../src/auth`
- Modify: `packages/daemon/test/pty-manager.test.ts` — change `./pty-manager` → `../src/pty-manager`
- Modify: `packages/daemon/test/websocket-hub.test.ts` — change `./websocket-hub` → `../src/websocket-hub`
- Modify: `packages/cli/src/daemon-client.ts` — change `../shared/types` → `shared`
- Modify: `packages/cli/src/index.ts` — change `../shared/types` → `shared`
- Modify: `packages/cli/src/daemon-client.ts` — change `../daemon/index.ts` path to `../../daemon/src/index.ts`
- Modify: `packages/cli/test/integration.test.ts` — change `../daemon/index.ts` path to `../../daemon/src/index.ts`

**Step 1: Fix all import paths**

For each file listed above, update import paths. The key rules:
- `../shared/types` → `shared` (workspace dependency)
- Test files: `./module` → `../src/module` (tests are now in `test/` not `src/`)
- CLI references to daemon entry: `../daemon/index.ts` → use `join(import.meta.dir, "../../daemon/src/index.ts")`

**Step 2: Run bun install at root**

```bash
cd /Users/timbroddin/Projects/workforce && bun install
```

**Step 3: Run all tests**

```bash
cd /Users/timbroddin/Projects/workforce && bun test packages/ --timeout 15000
```

Expected: All 34 tests pass.

**Step 4: Commit**

```bash
git add -A
git commit -m "fix: update import paths for monorepo structure"
```

---

## Task 3: Rename workforce → agenthub

Replace all `workforce` references with `agenthub` across the Bun codebase.

**Files:**
- Modify: `packages/daemon/src/index.ts` — `.workforce` → `.agenthub`, `WORKFORCE_SESSION` → `AGENTHUB_SESSION`, console log message
- Modify: `packages/daemon/src/pty-manager.ts` — `WORKFORCE_SESSION` → `AGENTHUB_SESSION`
- Modify: `packages/cli/src/index.ts` — `.workforce` → `.agenthub`, `WORKFORCE_SESSION` → `AGENTHUB_SESSION`, usage messages `workforce` → `agenthub`, tmux session name `workforce-` → `agenthub-`, launchd label `com.workforce.daemon` → `com.agenthub.daemon`
- Modify: `packages/cli/src/daemon-client.ts` — `.workforce` → `.agenthub`, console messages

**Step 1: Apply renames**

Search and replace in each file:
- `.workforce` → `.agenthub` (directory paths)
- `WORKFORCE_SESSION` → `AGENTHUB_SESSION` (env var)
- `workforce` → `agenthub` (in user-facing strings, tmux names, launchd labels)
- `com.workforce.daemon` → `com.agenthub.daemon`

Be careful NOT to rename:
- Git commit messages
- File paths in `packages/desktop/` (Swift code stays as-is for now)

**Step 2: Run all tests**

```bash
cd /Users/timbroddin/Projects/workforce && bun test packages/ --timeout 15000
```

Expected: All tests pass.

**Step 3: Commit**

```bash
git add -A
git commit -m "refactor: rename workforce to agenthub"
```

---

## Task 4: Transcript parser

**Files:**
- Create: `packages/shared/src/transcript.ts`
- Create: `packages/shared/test/transcript.test.ts`

**Step 1: Write the failing test**

```typescript
// packages/shared/test/transcript.test.ts
import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { parseTranscriptTokens } from "../src/transcript";

const TEST_DIR = "/tmp/agenthub-test-transcript";

beforeEach(() => {
  mkdirSync(TEST_DIR, { recursive: true });
});

afterEach(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
});

test("returns zeros for nonexistent file", async () => {
  const result = await parseTranscriptTokens("/tmp/nonexistent.jsonl");
  expect(result).toEqual({
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
  });
});

test("parses tokens from JSONL transcript", async () => {
  const filePath = join(TEST_DIR, "transcript.jsonl");
  const lines = [
    JSON.stringify({ type: "human", message: { role: "user", content: "hello" } }),
    JSON.stringify({
      type: "assistant",
      message: {
        role: "assistant",
        content: "hi",
        usage: { input_tokens: 100, output_tokens: 50, cache_creation_input_tokens: 10, cache_read_input_tokens: 20 },
      },
    }),
    JSON.stringify({
      type: "assistant",
      message: {
        role: "assistant",
        content: "bye",
        usage: { input_tokens: 200, output_tokens: 80 },
      },
    }),
  ];
  await Bun.write(filePath, lines.join("\n"));

  const result = await parseTranscriptTokens(filePath);
  expect(result.inputTokens).toBe(300);
  expect(result.outputTokens).toBe(130);
  expect(result.cacheCreationTokens).toBe(10);
  expect(result.cacheReadTokens).toBe(20);
});

test("skips lines without usage", async () => {
  const filePath = join(TEST_DIR, "transcript2.jsonl");
  const lines = [
    JSON.stringify({ type: "human", message: { role: "user", content: "test" } }),
    JSON.stringify({ type: "assistant", message: { role: "assistant", content: "ok" } }),
  ];
  await Bun.write(filePath, lines.join("\n"));

  const result = await parseTranscriptTokens(filePath);
  expect(result.inputTokens).toBe(0);
  expect(result.outputTokens).toBe(0);
});

test("handles empty file", async () => {
  const filePath = join(TEST_DIR, "empty.jsonl");
  await Bun.write(filePath, "");

  const result = await parseTranscriptTokens(filePath);
  expect(result.inputTokens).toBe(0);
});

test("handles malformed JSON lines gracefully", async () => {
  const filePath = join(TEST_DIR, "bad.jsonl");
  const lines = [
    "not json",
    JSON.stringify({
      type: "assistant",
      message: { role: "assistant", content: "ok", usage: { input_tokens: 50, output_tokens: 25 } },
    }),
    "{broken",
  ];
  await Bun.write(filePath, lines.join("\n"));

  const result = await parseTranscriptTokens(filePath);
  expect(result.inputTokens).toBe(50);
  expect(result.outputTokens).toBe(25);
});
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/timbroddin/Projects/workforce && bun test packages/shared/test/transcript.test.ts`
Expected: FAIL — module not found

**Step 3: Write implementation**

```typescript
// packages/shared/src/transcript.ts
import { existsSync } from "node:fs";

export interface TokenSummary {
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
}

export async function parseTranscriptTokens(filePath: string): Promise<TokenSummary> {
  const summary: TokenSummary = {
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
  };

  if (!existsSync(filePath)) return summary;

  const file = Bun.file(filePath);
  const text = await file.text();
  if (!text.trim()) return summary;

  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      const usage = entry?.message?.usage;
      if (!usage) continue;
      summary.inputTokens += usage.input_tokens ?? 0;
      summary.outputTokens += usage.output_tokens ?? 0;
      summary.cacheCreationTokens += usage.cache_creation_input_tokens ?? 0;
      summary.cacheReadTokens += usage.cache_read_input_tokens ?? 0;
    } catch {
      // Skip malformed lines
    }
  }

  return summary;
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/timbroddin/Projects/workforce && bun test packages/shared/test/transcript.test.ts`
Expected: PASS (5 tests)

**Step 5: Commit**

```bash
git add packages/shared/src/transcript.ts packages/shared/test/transcript.test.ts
git commit -m "feat: add transcript JSONL parser for token tracking"
```

---

## Task 5: Integrate token tracking into session-end hook

**Files:**
- Modify: `packages/cli/src/index.ts` — change `session-end` handler to parse transcript and send `updateTokens` before `deregister`

**Step 1: Add transcript import and update session-end handler**

In `packages/cli/src/index.ts`, add import at top:

```typescript
import { parseTranscriptTokens } from "shared/transcript";
```

Change the `session-end` entry in `messageMap` handling. Replace the simple `session-end` message with a function that:
1. If `event.transcript_path` exists, calls `parseTranscriptTokens(event.transcript_path)`
2. Sends `updateTokens` event first
3. Then sends `deregister` event

The `handleHook` function needs to be updated to handle `session-end` specially:

```typescript
// In handleHook, before the messageMap lookup:
if (hookName === "session-end") {
  // Parse transcript for token tracking
  if (event.transcript_path) {
    const tokens = await parseTranscriptTokens(event.transcript_path);
    await client.postEvent({
      type: "updateTokens",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      input_tokens: tokens.inputTokens,
      output_tokens: tokens.outputTokens,
      cache_creation_tokens: tokens.cacheCreationTokens,
      cache_read_tokens: tokens.cacheReadTokens,
    });
  }
  // Then deregister
  await client.postEvent({
    type: "deregister",
    session_id: sessionId,
    cwd: event.cwd,
    timestamp: now,
  });
  return;
}
```

**Step 2: Run tests**

Run: `cd /Users/timbroddin/Projects/workforce && bun test packages/ --timeout 15000`
Expected: All tests pass.

**Step 3: Commit**

```bash
git add packages/cli/src/index.ts
git commit -m "feat: parse transcript tokens on session-end before deregister"
```

---

## Task 6: Hook installation command

**Files:**
- Create: `packages/cli/src/hooks.ts`
- Create: `packages/cli/test/hooks.test.ts`
- Modify: `packages/cli/src/index.ts` — add `install-hooks` and `uninstall-hooks` commands

**Step 1: Write the failing test**

```typescript
// packages/cli/test/hooks.test.ts
import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { installHooks, uninstallHooks, HOOK_EVENTS } from "../src/hooks";

const TEST_DIR = "/tmp/agenthub-test-hooks";
const TEST_SETTINGS = join(TEST_DIR, ".claude", "settings.json");

beforeEach(() => {
  mkdirSync(join(TEST_DIR, ".claude"), { recursive: true });
});

afterEach(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
});

test("HOOK_EVENTS contains all 9 events", () => {
  expect(HOOK_EVENTS).toHaveLength(9);
});

test("installHooks creates settings.json with all hooks", async () => {
  await installHooks("/usr/local/bin/agenthub", TEST_SETTINGS);
  const settings = JSON.parse(await Bun.file(TEST_SETTINGS).text());
  expect(settings.hooks).toBeDefined();
  expect(Object.keys(settings.hooks)).toHaveLength(9);
  expect(settings.hooks.SessionStart[0].hooks[0].command).toContain("agenthub session-start");
});

test("installHooks merges with existing settings", async () => {
  await Bun.write(TEST_SETTINGS, JSON.stringify({ env: { DEBUG: "1" } }));
  await installHooks("/usr/local/bin/agenthub", TEST_SETTINGS);
  const settings = JSON.parse(await Bun.file(TEST_SETTINGS).text());
  expect(settings.env.DEBUG).toBe("1");
  expect(settings.hooks).toBeDefined();
});

test("installHooks preserves existing non-agenthub hooks", async () => {
  const existing = {
    hooks: {
      SessionStart: [
        { matcher: "", hooks: [{ type: "command", command: "some-other-tool start" }] },
      ],
    },
  };
  await Bun.write(TEST_SETTINGS, JSON.stringify(existing));
  await installHooks("/usr/local/bin/agenthub", TEST_SETTINGS);
  const settings = JSON.parse(await Bun.file(TEST_SETTINGS).text());
  // Should have both the existing hook and the agenthub hook
  expect(settings.hooks.SessionStart.length).toBe(2);
});

test("uninstallHooks removes only agenthub hooks", async () => {
  const existing = {
    hooks: {
      SessionStart: [
        { matcher: "", hooks: [{ type: "command", command: "some-other-tool start" }] },
        { matcher: "", hooks: [{ type: "command", command: "/usr/local/bin/agenthub session-start" }] },
      ],
    },
  };
  await Bun.write(TEST_SETTINGS, JSON.stringify(existing));
  await uninstallHooks(TEST_SETTINGS);
  const settings = JSON.parse(await Bun.file(TEST_SETTINGS).text());
  expect(settings.hooks.SessionStart).toHaveLength(1);
  expect(settings.hooks.SessionStart[0].hooks[0].command).toContain("some-other-tool");
});

test("uninstallHooks handles no settings file", async () => {
  // Should not throw
  await uninstallHooks(join(TEST_DIR, "nonexistent", "settings.json"));
});
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/timbroddin/Projects/workforce && bun test packages/cli/test/hooks.test.ts`
Expected: FAIL

**Step 3: Write implementation**

```typescript
// packages/cli/src/hooks.ts
import { existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

export const HOOK_EVENTS = [
  { claudeEvent: "SessionStart", subcommand: "session-start" },
  { claudeEvent: "PreToolUse", subcommand: "pre-tool-use" },
  { claudeEvent: "PostToolUse", subcommand: "post-tool-use" },
  { claudeEvent: "PostToolUseFailure", subcommand: "post-tool-use-failure" },
  { claudeEvent: "Notification", subcommand: "notification" },
  { claudeEvent: "SubagentStart", subcommand: "subagent-start" },
  { claudeEvent: "SubagentStop", subcommand: "subagent-stop" },
  { claudeEvent: "Stop", subcommand: "stop" },
  { claudeEvent: "SessionEnd", subcommand: "session-end" },
] as const;

function makeHookEntry(binaryPath: string, subcommand: string) {
  return {
    matcher: "",
    hooks: [{ type: "command", command: `${binaryPath} ${subcommand}` }],
  };
}

function isAgenthubHook(entry: any): boolean {
  return entry?.hooks?.some((h: any) =>
    typeof h.command === "string" && h.command.includes("agenthub")
  ) ?? false;
}

export async function installHooks(binaryPath: string, settingsPath: string): Promise<void> {
  let settings: any = {};

  if (existsSync(settingsPath)) {
    const text = await Bun.file(settingsPath).text();
    settings = JSON.parse(text);
  }

  if (!settings.hooks) {
    settings.hooks = {};
  }

  for (const { claudeEvent, subcommand } of HOOK_EVENTS) {
    if (!settings.hooks[claudeEvent]) {
      settings.hooks[claudeEvent] = [];
    }

    // Remove existing agenthub entries for this event
    settings.hooks[claudeEvent] = settings.hooks[claudeEvent].filter(
      (entry: any) => !isAgenthubHook(entry)
    );

    // Add new entry
    settings.hooks[claudeEvent].push(makeHookEntry(binaryPath, subcommand));
  }

  mkdirSync(dirname(settingsPath), { recursive: true });
  await Bun.write(settingsPath, JSON.stringify(settings, null, 2));
}

export async function uninstallHooks(settingsPath: string): Promise<void> {
  if (!existsSync(settingsPath)) return;

  const text = await Bun.file(settingsPath).text();
  const settings = JSON.parse(text);

  if (!settings.hooks) return;

  for (const key of Object.keys(settings.hooks)) {
    settings.hooks[key] = settings.hooks[key].filter(
      (entry: any) => !isAgenthubHook(entry)
    );
    // Remove empty arrays
    if (settings.hooks[key].length === 0) {
      delete settings.hooks[key];
    }
  }

  // Remove empty hooks object
  if (Object.keys(settings.hooks).length === 0) {
    delete settings.hooks;
  }

  await Bun.write(settingsPath, JSON.stringify(settings, null, 2));
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/timbroddin/Projects/workforce && bun test packages/cli/test/hooks.test.ts`
Expected: PASS (6 tests)

**Step 5: Wire into CLI**

In `packages/cli/src/index.ts`, add:

```typescript
import { installHooks, uninstallHooks } from "./hooks";
import { homedir } from "node:os";
import { join } from "node:path";
```

Add two new command handlers before the daemon-needing commands:

```typescript
if (command === "install-hooks") {
  const binaryPath = process.argv[0] ?? Bun.which("agenthub") ?? "agenthub";
  const settingsPath = join(homedir(), ".claude", "settings.json");
  await installHooks(binaryPath, settingsPath);
  console.log("Hooks installed to ~/.claude/settings.json");
  return;
}

if (command === "uninstall-hooks") {
  const settingsPath = join(homedir(), ".claude", "settings.json");
  await uninstallHooks(settingsPath);
  console.log("Hooks removed from ~/.claude/settings.json");
  return;
}
```

**Step 6: Run all tests**

Run: `cd /Users/timbroddin/Projects/workforce && bun test packages/ --timeout 15000`
Expected: All tests pass.

**Step 7: Commit**

```bash
git add packages/cli/src/hooks.ts packages/cli/test/hooks.test.ts packages/cli/src/index.ts
git commit -m "feat: add install-hooks and uninstall-hooks commands"
```

---

## Task 7: Add pid field to Agent and PTY manager

**Files:**
- Modify: `packages/shared/src/types.ts` — add `pid?: number` to `Agent` interface
- Modify: `packages/daemon/src/index.ts` — set `pid` from PTY session after spawn

**Step 1: Add pid to Agent type**

In `packages/shared/src/types.ts`, add to the `Agent` interface:

```typescript
  pid?: number;  // child process PID, set on spawn
```

Add after `totalCacheReadTokens`.

**Step 2: Set pid in daemon handleSpawn**

In `packages/daemon/src/index.ts`, in the `handleSpawn` function, after `ptyManager.spawn(...)` returns `agentId`, get the PID from the session:

```typescript
const session = ptyManager.getSession(agentId);
```

Then in the `store.addAgent(...)` call, add:

```typescript
  pid: session?.process.pid,
```

**Step 3: Run tests**

Run: `cd /Users/timbroddin/Projects/workforce && bun test packages/ --timeout 15000`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add packages/shared/src/types.ts packages/daemon/src/index.ts
git commit -m "feat: track child process PID in agent metadata"
```

---

## Task 8: Daemon resilience — orphan re-adoption

**Files:**
- Modify: `packages/shared/src/types.ts` — add `"orphaned"` to `AgentStatus`
- Modify: `packages/daemon/src/index.ts` — add orphan check after `store.load()`

**Step 1: Add orphaned status**

In `packages/shared/src/types.ts`, add `"orphaned"` to the `AgentStatus` union:

```typescript
export type AgentStatus =
  | "active"
  | "waitingForInput"
  | "waitingForPermission"
  | "idle"
  | "stopped"
  | "orphaned";
```

**Step 2: Add orphan check in daemon startup**

In `packages/daemon/src/index.ts`, after `await store.load();` and before `const server = Bun.serve(...)`, add:

```typescript
// Re-adopt orphaned agents from previous daemon run
for (const agent of store.listAgents()) {
  if (!agent.pid) {
    store.removeAgent(agent.sessionId);
    continue;
  }
  try {
    process.kill(agent.pid, 0); // Check if process is alive
    agent.status = "orphaned";
    agent.lastActivityAt = new Date().toISOString();
  } catch {
    // Process is dead, remove from store
    store.removeAgent(agent.sessionId);
  }
}
await store.persist();
```

**Step 3: Update DELETE handler to kill orphaned agents by PID**

In the `DELETE /api/agents/:id` handler in `packages/daemon/src/index.ts`, after `ptyManager.kill(agentId)`, add a fallback for orphaned agents:

```typescript
if (req.method === "DELETE") {
  const agent = store.getAgent(agentId);
  if (!agent) return Response.json({ error: "Not found" }, { status: 404 });
  // Try PTY kill first, then fall back to PID kill for orphaned agents
  if (ptyManager.getSession(agentId)) {
    ptyManager.kill(agentId);
  } else if (agent.pid) {
    try { process.kill(agent.pid, "SIGTERM"); } catch {}
  }
  store.removeAgent(agentId);
  store.persist();
  hub.broadcastControl({ type: "agents", agents: store.listAgents() });
  return Response.json({ ok: true });
}
```

**Step 4: Run tests**

Run: `cd /Users/timbroddin/Projects/workforce && bun test packages/ --timeout 15000`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add packages/shared/src/types.ts packages/daemon/src/index.ts
git commit -m "feat: re-adopt orphaned agent processes on daemon restart"
```

---

## Summary

| Task | What | Key Files |
|------|------|-----------|
| 1 | Monorepo file moves | All files moved to `packages/` |
| 2 | Fix imports | All `*.ts` files — update paths |
| 3 | Rename workforce → agenthub | daemon, cli, shared — strings and paths |
| 4 | Transcript parser | `packages/shared/src/transcript.ts` + test |
| 5 | Token tracking in session-end | `packages/cli/src/index.ts` |
| 6 | Hook installation | `packages/cli/src/hooks.ts` + test + CLI wiring |
| 7 | PID tracking | `packages/shared/src/types.ts`, daemon spawn |
| 8 | Orphan re-adoption | daemon startup, agent status, kill handler |
