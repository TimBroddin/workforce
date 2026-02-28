# Bun Daemon Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace tmux with a Bun daemon that manages agent PTYs directly, with a Bun CLI that communicates via WebSocket.

**Architecture:** A Bun daemon process owns all agent PTYs and serves HTTP + WebSocket. The CLI is a thin terminal client. Both use `~/.workforce/` for state. The macOS app continues working as-is during this phase.

**Tech Stack:** Bun (runtime, PTY, WebSocket, HTTP), TypeScript

**Design doc:** `docs/plans/2026-02-28-bun-daemon-design.md`

---

## Project Setup

### Task 1: Initialize Bun project

**Files:**
- Create: `daemon/package.json`
- Create: `daemon/tsconfig.json`
- Create: `daemon/bun.lock` (auto-generated)

**Step 1: Create package.json**

```json
{
  "name": "workforce",
  "version": "0.1.0",
  "type": "module",
  "bin": {
    "workforce": "./cli/index.ts"
  },
  "scripts": {
    "daemon": "bun run daemon/index.ts",
    "test": "bun test"
  }
}
```

Save to `daemon/package.json`.

**Step 2: Create tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "types": ["bun-types"],
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "./dist",
    "rootDir": "."
  },
  "include": ["daemon/**/*.ts", "cli/**/*.ts", "shared/**/*.ts"]
}
```

Save to `daemon/tsconfig.json`.

**Step 3: Install dependencies**

Run: `cd daemon && bun install`

**Step 4: Commit**

```bash
git add daemon/package.json daemon/tsconfig.json
git commit -m "chore: initialize Bun project for daemon and CLI"
```

---

## Shared Types

### Task 2: Define shared TypeScript types

**Files:**
- Create: `daemon/shared/types.ts`

**Step 1: Write the types file**

These types replicate the Swift models from `WorkforceKit/Sources/WorkforceKit/Models/`.

```typescript
// daemon/shared/types.ts

export type AgentStatus =
  | "active"
  | "waitingForInput"
  | "waitingForPermission"
  | "idle"
  | "stopped";

export interface Agent {
  sessionId: string;
  name: string;
  avatarSeed: string;
  cwd: string;
  agentType: string;
  model?: string;
  host?: string;
  status: AgentStatus;
  startedAt: string; // ISO8601
  lastActivityAt: string; // ISO8601
  currentToolName?: string;
  lastNotificationType?: string;
  subagentCount: number;
  paneTitle?: string;
  transcriptPath?: string;
  notificationMessage?: string;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalCacheCreationTokens: number;
  totalCacheReadTokens: number;
}

export type SocketMessageType =
  | "register"
  | "updateStatus"
  | "updateTool"
  | "notification"
  | "subagentStart"
  | "subagentStop"
  | "deregister"
  | "updateTokens";

// Incoming from CLI hooks — uses snake_case JSON keys
export interface SocketMessage {
  type: SocketMessageType;
  session_id: string;
  cwd: string;
  timestamp: string; // ISO8601
  name?: string;
  avatar_seed?: string;
  model?: string;
  status?: AgentStatus;
  tool_name?: string;
  notification_type?: string;
  agent_type?: string;
  tmux_session?: string;
  input_tokens?: number;
  output_tokens?: number;
  cache_creation_tokens?: number;
  cache_read_tokens?: number;
  transcript_path?: string;
  notification_message?: string;
}

// Hook event base (stdin JSON from Claude Code hooks)
export interface HookEventBase {
  session_id: string;
  cwd: string;
  hook_event_name: string;
  transcript_path?: string;
}

export interface ToolUseEvent extends HookEventBase {
  tool_name: string;
  tool_input?: {
    command?: string;
    file_path?: string;
  };
}

export interface NotificationEvent extends HookEventBase {
  type?: string;
  message?: string;
}

export interface SubagentEvent extends HookEventBase {
  agent_type?: string;
}

// Spawn request
export interface SpawnRequest {
  agentType: string;
  cwd: string;
  flags?: string[];
}

// Control WebSocket messages (client → daemon)
export type ClientControlMessage =
  | { type: "snapshot" }
  | { type: "spawn"; agentType: string; cwd: string; flags?: string[] }
  | { type: "kill"; agentId: string };

// Control WebSocket messages (daemon → client)
export type DaemonControlMessage =
  | { type: "agents"; agents: Agent[] }
  | { type: "event"; event: SocketMessage }
  | { type: "spawned"; agentId: string }
  | { type: "error"; message: string };

// Terminal WebSocket messages (text frames only — binary frames are raw PTY data)
export type TerminalControlMessage = { type: "resize"; cols: number; rows: number };

export type TerminalServerMessage = { type: "scrollback"; data: string }; // base64

// Allowed agent types and flags
export const ALLOWED_AGENT_TYPES = ["claude", "codex", "opencode", "bash"] as const;
export const ALLOWED_FLAGS = ["--dangerously-skip-permissions"] as const;
```

**Step 2: Commit**

```bash
git add daemon/shared/types.ts
git commit -m "feat: add shared TypeScript types mirroring Swift models"
```

---

## Daemon Core

### Task 3: Auth module

**Files:**
- Create: `daemon/daemon/auth.ts`
- Create: `daemon/daemon/auth.test.ts`

**Step 1: Write the failing test**

```typescript
// daemon/daemon/auth.test.ts
import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, unlinkSync, mkdirSync } from "node:fs";
import { generateToken, loadOrCreateToken, validateToken } from "./auth";

const TEST_DIR = "/tmp/workforce-test-auth";
const TEST_TOKEN_PATH = `${TEST_DIR}/daemon.token`;

beforeEach(() => {
  mkdirSync(TEST_DIR, { recursive: true });
});

afterEach(() => {
  if (existsSync(TEST_TOKEN_PATH)) unlinkSync(TEST_TOKEN_PATH);
});

test("generateToken returns a UUID-like string", () => {
  const token = generateToken();
  expect(token).toMatch(/^[a-f0-9-]{36}$/);
});

test("loadOrCreateToken creates token file if missing", async () => {
  const token = await loadOrCreateToken(TEST_TOKEN_PATH);
  expect(token).toMatch(/^[a-f0-9-]{36}$/);
  expect(existsSync(TEST_TOKEN_PATH)).toBe(true);
});

test("loadOrCreateToken returns existing token", async () => {
  const token1 = await loadOrCreateToken(TEST_TOKEN_PATH);
  const token2 = await loadOrCreateToken(TEST_TOKEN_PATH);
  expect(token1).toBe(token2);
});

test("validateToken accepts valid token", async () => {
  const token = await loadOrCreateToken(TEST_TOKEN_PATH);
  expect(validateToken(`Bearer ${token}`, token)).toBe(true);
});

test("validateToken rejects invalid token", async () => {
  expect(validateToken("Bearer wrong", "correct")).toBe(false);
});

test("validateToken accepts query param token", async () => {
  const token = "test-token-123";
  expect(validateToken(null, token, token)).toBe(true);
});
```

**Step 2: Run test to verify it fails**

Run: `cd daemon && bun test daemon/auth.test.ts`
Expected: FAIL — module not found

**Step 3: Write implementation**

```typescript
// daemon/daemon/auth.ts
import { existsSync, chmodSync } from "node:fs";

export function generateToken(): string {
  return crypto.randomUUID();
}

export async function loadOrCreateToken(tokenPath: string): Promise<string> {
  if (existsSync(tokenPath)) {
    const file = Bun.file(tokenPath);
    const existing = (await file.text()).trim();
    if (existing) return existing;
  }
  const token = generateToken();
  await Bun.write(tokenPath, token);
  chmodSync(tokenPath, 0o600);
  return token;
}

export function validateToken(
  authHeader: string | null,
  expectedToken: string,
  queryToken?: string
): boolean {
  if (queryToken === expectedToken) return true;
  if (!authHeader) return false;
  const token = authHeader.replace("Bearer ", "");
  return token === expectedToken;
}
```

**Step 4: Run test to verify it passes**

Run: `cd daemon && bun test daemon/auth.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add daemon/daemon/auth.ts daemon/daemon/auth.test.ts
git commit -m "feat: add auth token generation and validation"
```

---

### Task 4: Agent store

**Files:**
- Create: `daemon/daemon/agent-store.ts`
- Create: `daemon/daemon/agent-store.test.ts`

**Step 1: Write the failing test**

```typescript
// daemon/daemon/agent-store.test.ts
import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, unlinkSync, mkdirSync, rmSync } from "node:fs";
import { AgentStore } from "./agent-store";
import type { Agent, SocketMessage } from "../shared/types";

const TEST_DIR = "/tmp/workforce-test-store";
const TEST_AGENTS_PATH = `${TEST_DIR}/agents.json`;

beforeEach(() => {
  mkdirSync(TEST_DIR, { recursive: true });
});

afterEach(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
});

function makeAgent(overrides: Partial<Agent> = {}): Agent {
  return {
    sessionId: "test-123",
    name: "Test Agent",
    avatarSeed: "seed",
    cwd: "/tmp",
    agentType: "claude",
    status: "active",
    startedAt: new Date().toISOString(),
    lastActivityAt: new Date().toISOString(),
    subagentCount: 0,
    totalInputTokens: 0,
    totalOutputTokens: 0,
    totalCacheCreationTokens: 0,
    totalCacheReadTokens: 0,
    ...overrides,
  };
}

test("addAgent stores and retrieves agent", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  const agent = makeAgent();
  store.addAgent(agent);
  expect(store.getAgent("test-123")).toEqual(agent);
});

test("listAgents returns all agents", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent({ sessionId: "a" }));
  store.addAgent(makeAgent({ sessionId: "b" }));
  expect(store.listAgents()).toHaveLength(2);
});

test("removeAgent deletes agent", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  store.removeAgent("test-123");
  expect(store.getAgent("test-123")).toBeUndefined();
});

test("applyEvent updateStatus changes agent status", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  const msg: SocketMessage = {
    type: "updateStatus",
    session_id: "test-123",
    cwd: "/tmp",
    timestamp: new Date().toISOString(),
    status: "idle",
  };
  store.applyEvent(msg);
  expect(store.getAgent("test-123")?.status).toBe("idle");
});

test("applyEvent updateTool sets currentToolName", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  const msg: SocketMessage = {
    type: "updateTool",
    session_id: "test-123",
    cwd: "/tmp",
    timestamp: new Date().toISOString(),
    tool_name: "bash",
  };
  store.applyEvent(msg);
  expect(store.getAgent("test-123")?.currentToolName).toBe("bash");
});

test("applyEvent updateTokens accumulates tokens", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  const msg: SocketMessage = {
    type: "updateTokens",
    session_id: "test-123",
    cwd: "/tmp",
    timestamp: new Date().toISOString(),
    input_tokens: 100,
    output_tokens: 50,
  };
  store.applyEvent(msg);
  const agent = store.getAgent("test-123");
  expect(agent?.totalInputTokens).toBe(100);
  expect(agent?.totalOutputTokens).toBe(50);
});

test("applyEvent deregister removes agent", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  const msg: SocketMessage = {
    type: "deregister",
    session_id: "test-123",
    cwd: "/tmp",
    timestamp: new Date().toISOString(),
  };
  store.applyEvent(msg);
  expect(store.getAgent("test-123")).toBeUndefined();
});

test("persist and load round-trips agents", async () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  await store.persist();

  const store2 = new AgentStore(TEST_AGENTS_PATH);
  await store2.load();
  expect(store2.getAgent("test-123")).toBeDefined();
});
```

**Step 2: Run test to verify it fails**

Run: `cd daemon && bun test daemon/agent-store.test.ts`
Expected: FAIL — module not found

**Step 3: Write implementation**

```typescript
// daemon/daemon/agent-store.ts
import { existsSync } from "node:fs";
import type { Agent, SocketMessage } from "../shared/types";

export class AgentStore {
  private agents = new Map<string, Agent>();
  private persistPath: string;

  constructor(persistPath: string) {
    this.persistPath = persistPath;
  }

  addAgent(agent: Agent): void {
    this.agents.set(agent.sessionId, agent);
  }

  getAgent(sessionId: string): Agent | undefined {
    return this.agents.get(sessionId);
  }

  listAgents(): Agent[] {
    return [...this.agents.values()].sort(
      (a, b) => new Date(a.startedAt).getTime() - new Date(b.startedAt).getTime()
    );
  }

  removeAgent(sessionId: string): void {
    this.agents.delete(sessionId);
  }

  applyEvent(msg: SocketMessage): void {
    const agent = this.agents.get(msg.session_id);

    switch (msg.type) {
      case "register": {
        if (agent) {
          agent.status = msg.status ?? "active";
          agent.lastActivityAt = msg.timestamp;
        }
        break;
      }
      case "updateStatus": {
        if (agent) {
          agent.status = msg.status ?? agent.status;
          agent.lastActivityAt = msg.timestamp;
          if (msg.transcript_path) agent.transcriptPath = msg.transcript_path;
        }
        break;
      }
      case "updateTool": {
        if (agent) {
          agent.currentToolName = msg.tool_name ?? undefined;
          agent.status = msg.status ?? agent.status;
          agent.lastActivityAt = msg.timestamp;
        }
        break;
      }
      case "notification": {
        if (agent) {
          agent.status = msg.status ?? agent.status;
          agent.lastNotificationType = msg.notification_type;
          agent.notificationMessage = msg.notification_message;
          agent.lastActivityAt = msg.timestamp;
          if (msg.transcript_path) agent.transcriptPath = msg.transcript_path;
        }
        break;
      }
      case "subagentStart": {
        if (agent) {
          agent.subagentCount += 1;
          agent.status = msg.status ?? agent.status;
          agent.lastActivityAt = msg.timestamp;
        }
        break;
      }
      case "subagentStop": {
        if (agent) {
          agent.subagentCount = Math.max(0, agent.subagentCount - 1);
          agent.lastActivityAt = msg.timestamp;
        }
        break;
      }
      case "updateTokens": {
        if (agent) {
          agent.totalInputTokens += msg.input_tokens ?? 0;
          agent.totalOutputTokens += msg.output_tokens ?? 0;
          agent.totalCacheCreationTokens += msg.cache_creation_tokens ?? 0;
          agent.totalCacheReadTokens += msg.cache_read_tokens ?? 0;
          agent.lastActivityAt = msg.timestamp;
        }
        break;
      }
      case "deregister": {
        this.agents.delete(msg.session_id);
        break;
      }
    }
  }

  async persist(): Promise<void> {
    const data = JSON.stringify(this.listAgents(), null, 2);
    await Bun.write(this.persistPath, data);
  }

  async load(): Promise<void> {
    if (!existsSync(this.persistPath)) return;
    const file = Bun.file(this.persistPath);
    const text = await file.text();
    const agents: Agent[] = JSON.parse(text);
    for (const agent of agents) {
      this.agents.set(agent.sessionId, agent);
    }
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd daemon && bun test daemon/agent-store.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add daemon/daemon/agent-store.ts daemon/daemon/agent-store.test.ts
git commit -m "feat: add agent store with event handling and persistence"
```

---

### Task 5: PTY manager

**Files:**
- Create: `daemon/daemon/pty-manager.ts`
- Create: `daemon/daemon/pty-manager.test.ts`

**Step 1: Write the failing test**

```typescript
// daemon/daemon/pty-manager.test.ts
import { test, expect, afterEach } from "bun:test";
import { PTYManager } from "./pty-manager";

const manager = new PTYManager();

afterEach(() => {
  manager.killAll();
});

test("spawn creates a session and returns an id", () => {
  const id = manager.spawn({ cmd: ["echo", "hello"], cwd: "/tmp" });
  expect(id).toMatch(/^[a-f0-9-]{36}$/);
  expect(manager.getSession(id)).toBeDefined();
});

test("listSessions returns all sessions", () => {
  manager.spawn({ cmd: ["sleep", "10"], cwd: "/tmp" });
  manager.spawn({ cmd: ["sleep", "10"], cwd: "/tmp" });
  expect(manager.listSessions()).toHaveLength(2);
});

test("kill terminates session", async () => {
  const id = manager.spawn({ cmd: ["sleep", "60"], cwd: "/tmp" });
  manager.kill(id);
  // Give process time to exit
  await Bun.sleep(100);
  expect(manager.getSession(id)).toBeUndefined();
});

test("resize updates session dimensions", () => {
  const id = manager.spawn({ cmd: ["sleep", "10"], cwd: "/tmp" });
  manager.resize(id, 120, 40);
  const session = manager.getSession(id);
  expect(session?.cols).toBe(120);
  expect(session?.rows).toBe(40);
});

test("scrollback captures output", async () => {
  const id = manager.spawn({ cmd: ["echo", "hello world"], cwd: "/tmp" });
  // Wait for output
  await Bun.sleep(200);
  const scrollback = manager.getScrollback(id);
  expect(scrollback.length).toBeGreaterThan(0);
});

test("subscribe and unsubscribe work", () => {
  const id = manager.spawn({ cmd: ["sleep", "10"], cwd: "/tmp" });
  const received: Uint8Array[] = [];
  const sub = (data: Uint8Array) => { received.push(data); };
  manager.subscribe(id, sub);
  manager.unsubscribe(id, sub);
  const session = manager.getSession(id);
  expect(session?.subscribers.size).toBe(0);
});
```

**Step 2: Run test to verify it fails**

Run: `cd daemon && bun test daemon/pty-manager.test.ts`
Expected: FAIL — module not found

**Step 3: Write implementation**

Bun's PTY API reference: [Bun.spawn terminal docs](https://bun.com/docs/runtime/child-process)

```typescript
// daemon/daemon/pty-manager.ts

type OutputSubscriber = (data: Uint8Array) => void;

export interface PTYSession {
  id: string;
  process: ReturnType<typeof Bun.spawn>;
  terminal: {
    write(data: string | BufferSource): number;
    resize(cols: number, rows: number): void;
    close(): void;
  };
  cols: number;
  rows: number;
  scrollback: Uint8Array[];
  scrollbackSize: number;
  subscribers: Set<OutputSubscriber>;
  onExit?: (id: string) => void;
}

const MAX_SCROLLBACK_BYTES = 1024 * 1024; // ~1MB

export class PTYManager {
  private sessions = new Map<string, PTYSession>();

  spawn(opts: {
    cmd: string[];
    cwd: string;
    cols?: number;
    rows?: number;
    env?: Record<string, string>;
    onExit?: (id: string) => void;
  }): string {
    const id = crypto.randomUUID();
    const cols = opts.cols ?? 80;
    const rows = opts.rows ?? 24;

    const session: PTYSession = {
      id,
      cols,
      rows,
      scrollback: [],
      scrollbackSize: 0,
      subscribers: new Set(),
      onExit: opts.onExit,
    } as PTYSession;

    const proc = Bun.spawn({
      cmd: opts.cmd,
      cwd: opts.cwd,
      env: opts.env ?? { ...process.env, WORKFORCE_SESSION: id },
      terminal: {
        cols,
        rows,
        data: (_terminal, data) => {
          // Store in scrollback
          session.scrollback.push(data);
          session.scrollbackSize += data.byteLength;

          // Trim scrollback if too large
          while (session.scrollbackSize > MAX_SCROLLBACK_BYTES && session.scrollback.length > 1) {
            const removed = session.scrollback.shift()!;
            session.scrollbackSize -= removed.byteLength;
          }

          // Broadcast to subscribers
          for (const sub of session.subscribers) {
            sub(data);
          }
        },
        exit: () => {
          session.onExit?.(id);
          this.sessions.delete(id);
        },
      },
    });

    session.process = proc;
    session.terminal = proc.terminal!;
    this.sessions.set(id, session);
    return id;
  }

  getSession(id: string): PTYSession | undefined {
    return this.sessions.get(id);
  }

  listSessions(): PTYSession[] {
    return [...this.sessions.values()];
  }

  kill(id: string): void {
    const session = this.sessions.get(id);
    if (!session) return;
    session.process.kill("SIGHUP");
    // Fallback kill after 2 seconds
    setTimeout(() => {
      if (this.sessions.has(id)) {
        session.process.kill("SIGKILL");
        this.sessions.delete(id);
      }
    }, 2000);
  }

  killAll(): void {
    for (const id of this.sessions.keys()) {
      this.kill(id);
    }
  }

  resize(id: string, cols: number, rows: number): void {
    const session = this.sessions.get(id);
    if (!session) return;
    session.cols = cols;
    session.rows = rows;
    session.terminal.resize(cols, rows);
  }

  write(id: string, data: string | BufferSource): void {
    const session = this.sessions.get(id);
    if (!session) return;
    session.terminal.write(data);
  }

  getScrollback(id: string): Uint8Array[] {
    return this.sessions.get(id)?.scrollback ?? [];
  }

  subscribe(id: string, subscriber: OutputSubscriber): void {
    this.sessions.get(id)?.subscribers.add(subscriber);
  }

  unsubscribe(id: string, subscriber: OutputSubscriber): void {
    this.sessions.get(id)?.subscribers.delete(subscriber);
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd daemon && bun test daemon/pty-manager.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add daemon/daemon/pty-manager.ts daemon/daemon/pty-manager.test.ts
git commit -m "feat: add PTY manager with spawn, resize, scrollback, and subscriptions"
```

---

### Task 6: WebSocket hub

**Files:**
- Create: `daemon/daemon/websocket-hub.ts`
- Create: `daemon/daemon/websocket-hub.test.ts`

**Step 1: Write the failing test**

```typescript
// daemon/daemon/websocket-hub.test.ts
import { test, expect } from "bun:test";
import { WebSocketHub } from "./websocket-hub";

test("WebSocketHub tracks control connections", () => {
  const hub = new WebSocketHub();
  const fakeWs = { send: () => {}, data: {} } as any;
  hub.addControlConnection(fakeWs);
  expect(hub.controlConnectionCount()).toBe(1);
  hub.removeControlConnection(fakeWs);
  expect(hub.controlConnectionCount()).toBe(0);
});

test("WebSocketHub tracks terminal connections by agent", () => {
  const hub = new WebSocketHub();
  const fakeWs = { send: () => {}, data: {} } as any;
  hub.addTerminalConnection("agent-1", fakeWs);
  expect(hub.terminalConnectionCount("agent-1")).toBe(1);
  hub.removeTerminalConnection("agent-1", fakeWs);
  expect(hub.terminalConnectionCount("agent-1")).toBe(0);
});

test("broadcastControl sends to all control connections", () => {
  const hub = new WebSocketHub();
  const sent: string[] = [];
  const fakeWs = { send: (msg: string) => sent.push(msg), data: {} } as any;
  hub.addControlConnection(fakeWs);
  hub.broadcastControl({ type: "agents", agents: [] });
  expect(sent).toHaveLength(1);
  expect(JSON.parse(sent[0]).type).toBe("agents");
});

test("broadcastTerminal sends binary to terminal connections", () => {
  const hub = new WebSocketHub();
  const sent: any[] = [];
  const fakeWs = { send: (msg: any) => sent.push(msg), data: {} } as any;
  hub.addTerminalConnection("agent-1", fakeWs);
  const data = new Uint8Array([72, 101, 108, 108, 111]);
  hub.broadcastTerminal("agent-1", data);
  expect(sent).toHaveLength(1);
});

test("getMinTerminalSize returns smallest dimensions", () => {
  const hub = new WebSocketHub();
  const ws1 = { send: () => {}, data: { cols: 120, rows: 40 } } as any;
  const ws2 = { send: () => {}, data: { cols: 80, rows: 24 } } as any;
  hub.addTerminalConnection("agent-1", ws1);
  hub.addTerminalConnection("agent-1", ws2);
  const size = hub.getMinTerminalSize("agent-1");
  expect(size).toEqual({ cols: 80, rows: 24 });
});
```

**Step 2: Run test to verify it fails**

Run: `cd daemon && bun test daemon/websocket-hub.test.ts`
Expected: FAIL — module not found

**Step 3: Write implementation**

```typescript
// daemon/daemon/websocket-hub.ts
import type { ServerWebSocket } from "bun";
import type { DaemonControlMessage } from "../shared/types";

export interface TerminalWsData {
  type: "terminal";
  agentId: string;
  cols: number;
  rows: number;
}

export interface ControlWsData {
  type: "control";
}

export type WsData = TerminalWsData | ControlWsData;

export class WebSocketHub {
  private controlConnections = new Set<ServerWebSocket<WsData> | { send: (msg: any) => void; data: any }>();
  private terminalConnections = new Map<string, Set<ServerWebSocket<WsData> | { send: (msg: any) => void; data: any }>>();

  addControlConnection(ws: ServerWebSocket<WsData> | any): void {
    this.controlConnections.add(ws);
  }

  removeControlConnection(ws: ServerWebSocket<WsData> | any): void {
    this.controlConnections.delete(ws);
  }

  controlConnectionCount(): number {
    return this.controlConnections.size;
  }

  addTerminalConnection(agentId: string, ws: ServerWebSocket<WsData> | any): void {
    if (!this.terminalConnections.has(agentId)) {
      this.terminalConnections.set(agentId, new Set());
    }
    this.terminalConnections.get(agentId)!.add(ws);
  }

  removeTerminalConnection(agentId: string, ws: ServerWebSocket<WsData> | any): void {
    this.terminalConnections.get(agentId)?.delete(ws);
    if (this.terminalConnections.get(agentId)?.size === 0) {
      this.terminalConnections.delete(agentId);
    }
  }

  terminalConnectionCount(agentId: string): number {
    return this.terminalConnections.get(agentId)?.size ?? 0;
  }

  broadcastControl(message: DaemonControlMessage): void {
    const json = JSON.stringify(message);
    for (const ws of this.controlConnections) {
      ws.send(json);
    }
  }

  broadcastTerminal(agentId: string, data: Uint8Array): void {
    const connections = this.terminalConnections.get(agentId);
    if (!connections) return;
    for (const ws of connections) {
      ws.send(data);
    }
  }

  getMinTerminalSize(agentId: string): { cols: number; rows: number } | null {
    const connections = this.terminalConnections.get(agentId);
    if (!connections || connections.size === 0) return null;

    let minCols = Infinity;
    let minRows = Infinity;
    for (const ws of connections) {
      const data = ws.data as TerminalWsData;
      if (data.cols && data.cols < minCols) minCols = data.cols;
      if (data.rows && data.rows < minRows) minRows = data.rows;
    }
    return { cols: minCols, rows: minRows };
  }

  getTerminalAgentIds(): string[] {
    return [...this.terminalConnections.keys()];
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd daemon && bun test daemon/websocket-hub.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add daemon/daemon/websocket-hub.ts daemon/daemon/websocket-hub.test.ts
git commit -m "feat: add WebSocket hub for control and terminal connections"
```

---

### Task 7: Daemon server (ties it all together)

**Files:**
- Create: `daemon/daemon/index.ts`

**Step 1: Write the daemon entry point**

```typescript
// daemon/daemon/index.ts
import { mkdirSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { loadOrCreateToken, validateToken } from "./auth";
import { AgentStore } from "./agent-store";
import { PTYManager } from "./pty-manager";
import { WebSocketHub, type WsData, type TerminalWsData } from "./websocket-hub";
import { ALLOWED_AGENT_TYPES, ALLOWED_FLAGS, type SpawnRequest, type SocketMessage, type ClientControlMessage, type TerminalControlMessage } from "../shared/types";

const WORKFORCE_DIR = join(homedir(), ".workforce");
const TOKEN_PATH = join(WORKFORCE_DIR, "daemon.token");
const PORT_PATH = join(WORKFORCE_DIR, "daemon.port");
const PID_PATH = join(WORKFORCE_DIR, "daemon.pid");
const AGENTS_PATH = join(WORKFORCE_DIR, "agents.json");

// Ensure config dir exists
mkdirSync(WORKFORCE_DIR, { recursive: true });

// Initialize components
const token = await loadOrCreateToken(TOKEN_PATH);
const store = new AgentStore(AGENTS_PATH);
await store.load();
const ptyManager = new PTYManager();
const hub = new WebSocketHub();

function agentShellCommand(agentType: string): string[] {
  const shell = process.env.SHELL ?? "/bin/zsh";
  return [shell, "-lc", agentType];
}

function handleSpawn(req: SpawnRequest): { agentId: string } | { error: string } {
  if (!ALLOWED_AGENT_TYPES.includes(req.agentType as any)) {
    return { error: `Disallowed agent type: ${req.agentType}` };
  }
  if (req.flags?.some((f) => !ALLOWED_FLAGS.includes(f as any))) {
    return { error: "Disallowed flag" };
  }

  const cmd = agentShellCommand(
    req.flags ? `${req.agentType} ${req.flags.join(" ")}` : req.agentType
  );

  const agentId = ptyManager.spawn({
    cmd,
    cwd: req.cwd,
    onExit: (id) => {
      const agent = store.getAgent(id);
      if (agent) {
        agent.status = "stopped";
        agent.lastActivityAt = new Date().toISOString();
        hub.broadcastControl({
          type: "event",
          event: {
            type: "deregister",
            session_id: id,
            cwd: agent.cwd,
            timestamp: new Date().toISOString(),
          },
        });
      }
      store.removeAgent(id);
      store.persist();
    },
  });

  const now = new Date().toISOString();
  store.addAgent({
    sessionId: agentId,
    name: req.agentType,
    avatarSeed: agentId.slice(0, 8),
    cwd: req.cwd,
    agentType: req.agentType,
    status: "active",
    startedAt: now,
    lastActivityAt: now,
    subagentCount: 0,
    totalInputTokens: 0,
    totalOutputTokens: 0,
    totalCacheCreationTokens: 0,
    totalCacheReadTokens: 0,
  });

  store.persist();

  hub.broadcastControl({ type: "agents", agents: store.listAgents() });

  return { agentId };
}

const server = Bun.serve<WsData>({
  hostname: "localhost",
  port: 0, // dynamic

  fetch(req, server) {
    const url = new URL(req.url);
    const authHeader = req.headers.get("authorization");
    const queryToken = url.searchParams.get("token") ?? undefined;

    // CORS preflight
    if (req.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
          "Access-Control-Allow-Headers": "Authorization, Content-Type",
        },
      });
    }

    // Auth check (except OPTIONS)
    if (!validateToken(authHeader, token, queryToken)) {
      return Response.json({ error: "Unauthorized" }, { status: 401 });
    }

    // WebSocket upgrades
    if (url.pathname === "/ws/control") {
      const upgraded = server.upgrade(req, {
        data: { type: "control" } as WsData,
      });
      if (upgraded) return undefined as any;
      return Response.json({ error: "WebSocket upgrade failed" }, { status: 400 });
    }

    const terminalMatch = url.pathname.match(/^\/ws\/terminal\/(.+)$/);
    if (terminalMatch) {
      const agentId = terminalMatch[1];
      if (!store.getAgent(agentId)) {
        return Response.json({ error: "Agent not found" }, { status: 404 });
      }
      const cols = parseInt(url.searchParams.get("cols") ?? "80");
      const rows = parseInt(url.searchParams.get("rows") ?? "24");
      const upgraded = server.upgrade(req, {
        data: { type: "terminal", agentId, cols, rows } as WsData,
      });
      if (upgraded) return undefined as any;
      return Response.json({ error: "WebSocket upgrade failed" }, { status: 400 });
    }

    // HTTP API routes
    if (req.method === "GET" && url.pathname === "/api/health") {
      return Response.json({ ok: true, agents: store.listAgents().length });
    }

    if (req.method === "GET" && url.pathname === "/api/agents") {
      return Response.json(store.listAgents());
    }

    const agentMatch = url.pathname.match(/^\/api\/agents\/(.+)$/);
    if (agentMatch) {
      const agentId = agentMatch[1];
      if (req.method === "GET") {
        const agent = store.getAgent(agentId);
        if (!agent) return Response.json({ error: "Not found" }, { status: 404 });
        return Response.json(agent);
      }
      if (req.method === "DELETE") {
        const agent = store.getAgent(agentId);
        if (!agent) return Response.json({ error: "Not found" }, { status: 404 });
        ptyManager.kill(agentId);
        store.removeAgent(agentId);
        store.persist();
        hub.broadcastControl({ type: "agents", agents: store.listAgents() });
        return Response.json({ ok: true });
      }
    }

    if (req.method === "POST" && url.pathname === "/api/agents") {
      return (async () => {
        const body = (await req.json()) as SpawnRequest;
        const result = handleSpawn(body);
        if ("error" in result) {
          return Response.json(result, { status: 400 });
        }
        return Response.json(result, { status: 201 });
      })();
    }

    if (req.method === "POST" && url.pathname === "/api/events") {
      return (async () => {
        const event = (await req.json()) as SocketMessage;
        store.applyEvent(event);
        store.persist();
        hub.broadcastControl({ type: "event", event });
        return Response.json({ ok: true });
      })();
    }

    // Legacy spawn endpoint for compatibility with Swift CLI
    if (req.method === "POST" && url.pathname === "/api/spawn") {
      return (async () => {
        const body = await req.json();
        const result = handleSpawn({
          agentType: body.agentType,
          cwd: body.cwd,
          flags: body.flags,
        });
        if ("error" in result) {
          return Response.json(result, { status: 400 });
        }
        return Response.json({ ok: true, sessionId: result.agentId });
      })();
    }

    return Response.json({ error: "Not found" }, { status: 404 });
  },

  websocket: {
    open(ws) {
      const data = ws.data;
      if (data.type === "control") {
        hub.addControlConnection(ws);
        // Send snapshot on connect
        ws.send(JSON.stringify({ type: "agents", agents: store.listAgents() }));
      } else if (data.type === "terminal") {
        const { agentId } = data as TerminalWsData;
        hub.addTerminalConnection(agentId, ws);

        // Subscribe to PTY output
        const subscriber = (output: Uint8Array) => ws.send(output);
        (ws as any)._ptySubscriber = subscriber;
        ptyManager.subscribe(agentId, subscriber);

        // Send scrollback
        const scrollback = ptyManager.getScrollback(agentId);
        for (const chunk of scrollback) {
          ws.send(chunk);
        }

        // Recalculate terminal size
        const size = hub.getMinTerminalSize(agentId);
        if (size) ptyManager.resize(agentId, size.cols, size.rows);
      }
    },

    message(ws, message) {
      const data = ws.data;

      if (data.type === "terminal") {
        const { agentId } = data as TerminalWsData;
        if (typeof message === "string") {
          // JSON control message (resize)
          const ctrl = JSON.parse(message) as TerminalControlMessage;
          if (ctrl.type === "resize") {
            (data as TerminalWsData).cols = ctrl.cols;
            (data as TerminalWsData).rows = ctrl.rows;
            const size = hub.getMinTerminalSize(agentId);
            if (size) ptyManager.resize(agentId, size.cols, size.rows);
          }
        } else {
          // Binary frame — stdin to PTY
          ptyManager.write(agentId, new Uint8Array(message as ArrayBuffer));
        }
      } else if (data.type === "control") {
        const msg = JSON.parse(message as string) as ClientControlMessage;
        switch (msg.type) {
          case "snapshot":
            ws.send(JSON.stringify({ type: "agents", agents: store.listAgents() }));
            break;
          case "spawn": {
            const result = handleSpawn({ agentType: msg.agentType, cwd: msg.cwd, flags: msg.flags });
            if ("error" in result) {
              ws.send(JSON.stringify({ type: "error", message: result.error }));
            } else {
              ws.send(JSON.stringify({ type: "spawned", agentId: result.agentId }));
            }
            break;
          }
          case "kill":
            ptyManager.kill(msg.agentId);
            store.removeAgent(msg.agentId);
            store.persist();
            hub.broadcastControl({ type: "agents", agents: store.listAgents() });
            break;
        }
      }
    },

    close(ws) {
      const data = ws.data;
      if (data.type === "control") {
        hub.removeControlConnection(ws);
      } else if (data.type === "terminal") {
        const { agentId } = data as TerminalWsData;
        const subscriber = (ws as any)._ptySubscriber;
        if (subscriber) ptyManager.unsubscribe(agentId, subscriber);
        hub.removeTerminalConnection(agentId, ws);

        // Recalculate terminal size
        const size = hub.getMinTerminalSize(agentId);
        if (size) ptyManager.resize(agentId, size.cols, size.rows);
      }
    },
  },
});

// Write port and PID files
await Bun.write(PORT_PATH, String(server.port));
await Bun.write(PID_PATH, String(process.pid));

console.log(`Workforce daemon running on port ${server.port}`);

// Graceful shutdown
process.on("SIGTERM", async () => {
  console.log("Shutting down...");
  ptyManager.killAll();
  await store.persist();
  server.stop();
  process.exit(0);
});

process.on("SIGINT", async () => {
  console.log("Shutting down...");
  ptyManager.killAll();
  await store.persist();
  server.stop();
  process.exit(0);
});
```

**Step 2: Smoke test — start daemon**

Run: `cd daemon && bun run daemon/index.ts &`
Expected: `Workforce daemon running on port XXXXX`

Run: `curl -s -H "Authorization: Bearer $(cat ~/.workforce/daemon.token)" http://localhost:$(cat ~/.workforce/daemon.port)/api/health`
Expected: `{"ok":true,"agents":0}`

Kill the daemon after testing.

**Step 3: Commit**

```bash
git add daemon/daemon/index.ts
git commit -m "feat: add daemon server with HTTP API, WebSocket, and PTY management"
```

---

## CLI

### Task 8: Daemon client module

**Files:**
- Create: `daemon/cli/daemon-client.ts`

**Step 1: Write daemon client**

```typescript
// daemon/cli/daemon-client.ts
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Agent, SpawnRequest } from "../shared/types";

const WORKFORCE_DIR = join(homedir(), ".workforce");
const TOKEN_PATH = join(WORKFORCE_DIR, "daemon.token");
const PORT_PATH = join(WORKFORCE_DIR, "daemon.port");
const PID_PATH = join(WORKFORCE_DIR, "daemon.pid");
const DAEMON_ENTRY = join(import.meta.dir, "../daemon/index.ts");

export async function ensureDaemon(): Promise<{ port: number; token: string }> {
  // Check if daemon is already running
  if (existsSync(PID_PATH) && existsSync(PORT_PATH)) {
    const pid = parseInt(await Bun.file(PID_PATH).text());
    try {
      process.kill(pid, 0); // Check if process exists
      const port = parseInt(await Bun.file(PORT_PATH).text());
      const token = await Bun.file(TOKEN_PATH).text();
      return { port, token: token.trim() };
    } catch {
      // PID stale, daemon not running
    }
  }

  // Start daemon
  console.log("Starting workforce daemon...");
  const proc = Bun.spawn({
    cmd: ["bun", "run", DAEMON_ENTRY],
    stdio: ["ignore", "pipe", "pipe"],
  });

  // Wait for port file to appear
  for (let i = 0; i < 50; i++) {
    await Bun.sleep(100);
    if (existsSync(PORT_PATH) && existsSync(TOKEN_PATH)) {
      try {
        const port = parseInt(await Bun.file(PORT_PATH).text());
        const token = (await Bun.file(TOKEN_PATH).text()).trim();
        // Verify daemon is responding
        const res = await fetch(`http://localhost:${port}/api/health`, {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (res.ok) {
          console.log(`Daemon running on port ${port}`);
          return { port, token };
        }
      } catch {
        // Not ready yet
      }
    }
  }
  throw new Error("Failed to start daemon");
}

export class DaemonClient {
  constructor(
    private port: number,
    private token: string
  ) {}

  private url(path: string): string {
    return `http://localhost:${this.port}${path}`;
  }

  private wsUrl(path: string): string {
    return `ws://localhost:${this.port}${path}?token=${this.token}`;
  }

  private headers(): Record<string, string> {
    return {
      Authorization: `Bearer ${this.token}`,
      "Content-Type": "application/json",
    };
  }

  async listAgents(): Promise<Agent[]> {
    const res = await fetch(this.url("/api/agents"), { headers: this.headers() });
    return res.json();
  }

  async getAgent(id: string): Promise<Agent | null> {
    const res = await fetch(this.url(`/api/agents/${id}`), { headers: this.headers() });
    if (!res.ok) return null;
    return res.json();
  }

  async spawnAgent(req: SpawnRequest): Promise<string> {
    const res = await fetch(this.url("/api/agents"), {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(req),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error);
    return data.agentId;
  }

  async killAgent(id: string): Promise<void> {
    const res = await fetch(this.url(`/api/agents/${id}`), {
      method: "DELETE",
      headers: this.headers(),
    });
    if (!res.ok) {
      const data = await res.json();
      throw new Error(data.error);
    }
  }

  async postEvent(event: any): Promise<void> {
    await fetch(this.url("/api/events"), {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(event),
    });
  }

  controlWsUrl(): string {
    return this.wsUrl("/ws/control");
  }

  terminalWsUrl(agentId: string, cols?: number, rows?: number): string {
    let url = this.wsUrl(`/ws/terminal/${agentId}`);
    if (cols) url += `&cols=${cols}`;
    if (rows) url += `&rows=${rows}`;
    return url;
  }
}
```

**Step 2: Commit**

```bash
git add daemon/cli/daemon-client.ts
git commit -m "feat: add daemon client with auto-start and HTTP/WS helpers"
```

---

### Task 9: Terminal mode (raw mode + WebSocket piping)

**Files:**
- Create: `daemon/cli/terminal.ts`

**Step 1: Write terminal module**

```typescript
// daemon/cli/terminal.ts
import type { DaemonClient } from "./daemon-client";

export async function attachTerminal(
  client: DaemonClient,
  agentId: string
): Promise<void> {
  const cols = process.stdout.columns ?? 80;
  const rows = process.stdout.rows ?? 24;

  const wsUrl = client.terminalWsUrl(agentId, cols, rows);
  const ws = new WebSocket(wsUrl);

  return new Promise<void>((resolve, reject) => {
    let connected = false;

    ws.binaryType = "arraybuffer";

    ws.onopen = () => {
      connected = true;

      // Enter raw mode
      if (process.stdin.isTTY) {
        process.stdin.setRawMode(true);
      }
      process.stdin.resume();

      // Forward stdin to WebSocket as binary
      process.stdin.on("data", (data: Buffer) => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(data);
        }
      });

      // Handle terminal resize
      process.stdout.on("resize", () => {
        const newCols = process.stdout.columns;
        const newRows = process.stdout.rows;
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: "resize", cols: newCols, rows: newRows }));
        }
      });
    };

    ws.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        // Binary frame — PTY output
        process.stdout.write(Buffer.from(event.data));
      } else {
        // Text frame — control message (scrollback, etc.)
        // Could handle scrollback here if needed
      }
    };

    ws.onclose = () => {
      cleanup();
      resolve();
    };

    ws.onerror = (err) => {
      cleanup();
      if (!connected) {
        reject(new Error("Failed to connect to agent terminal"));
      } else {
        resolve();
      }
    };

    function cleanup() {
      if (process.stdin.isTTY) {
        process.stdin.setRawMode(false);
      }
      process.stdin.pause();
      process.stdin.removeAllListeners("data");
      process.stdout.removeAllListeners("resize");
    }

    // Handle SIGINT — detach gracefully
    process.on("SIGINT", () => {
      ws.close();
    });
  });
}
```

**Step 2: Commit**

```bash
git add daemon/cli/terminal.ts
git commit -m "feat: add terminal raw mode and WebSocket piping for CLI"
```

---

### Task 10: CLI entry point and commands

**Files:**
- Create: `daemon/cli/index.ts`

**Step 1: Write CLI entry point**

```typescript
#!/usr/bin/env bun
// daemon/cli/index.ts
import { ensureDaemon, DaemonClient } from "./daemon-client";
import { attachTerminal } from "./terminal";
import { ALLOWED_AGENT_TYPES } from "../shared/types";
import { homedir } from "node:os";
import { join } from "node:path";
import { existsSync } from "node:fs";

const args = process.argv.slice(2);
const command = args[0] ?? "claude";

async function main() {
  // Daemon management commands (don't need daemon running)
  if (command === "daemon") {
    const sub = args[1];
    if (sub === "start") {
      await ensureDaemon();
      return;
    }
    if (sub === "stop") {
      return daemonStop();
    }
    if (sub === "status") {
      return daemonStatus();
    }
    console.log("Usage: workforce daemon [start|stop|status]");
    return;
  }

  if (command === "install") {
    return installLaunchd();
  }

  if (command === "uninstall") {
    return uninstallLaunchd();
  }

  // Commands that need daemon
  const { port, token } = await ensureDaemon();
  const client = new DaemonClient(port, token);

  if (command === "list") {
    const agents = await client.listAgents();
    if (agents.length === 0) {
      console.log("No running agents.");
      return;
    }
    for (const a of agents) {
      const status = a.status.padEnd(20);
      const type = a.agentType.padEnd(10);
      console.log(`${a.sessionId.slice(0, 8)}  ${type}  ${status}  ${a.cwd}`);
    }
    return;
  }

  if (command === "attach") {
    const agentId = args[1];
    if (!agentId) {
      console.error("Usage: workforce attach <agent-id>");
      process.exit(1);
    }
    // Support short IDs
    const agents = await client.listAgents();
    const match = agents.find(
      (a) => a.sessionId === agentId || a.sessionId.startsWith(agentId)
    );
    if (!match) {
      console.error(`Agent not found: ${agentId}`);
      process.exit(1);
    }
    await attachTerminal(client, match.sessionId);
    return;
  }

  if (command === "kill") {
    const agentId = args[1];
    if (!agentId) {
      console.error("Usage: workforce kill <agent-id>");
      process.exit(1);
    }
    const agents = await client.listAgents();
    const match = agents.find(
      (a) => a.sessionId === agentId || a.sessionId.startsWith(agentId)
    );
    if (!match) {
      console.error(`Agent not found: ${agentId}`);
      process.exit(1);
    }
    await client.killAgent(match.sessionId);
    console.log(`Killed agent ${match.sessionId.slice(0, 8)}`);
    return;
  }

  // Hook subcommands (called by Claude Code hooks)
  const hookCommands = [
    "session-start", "session-end",
    "pre-tool-use", "post-tool-use", "post-tool-use-failure",
    "notification", "stop",
    "subagent-start", "subagent-stop",
  ];

  if (hookCommands.includes(command)) {
    return handleHook(command, client);
  }

  // Default: spawn agent
  const agentType = ALLOWED_AGENT_TYPES.includes(command as any) ? command : "claude";
  const flags = args.filter((a) => a.startsWith("--"));
  const useTmux = flags.includes("--tmux");
  const useZellij = flags.includes("--zellij");
  const agentFlags = flags.filter((f) => f !== "--tmux" && f !== "--zellij");

  const cwd = process.cwd();
  const agentId = await client.spawnAgent({ agentType, cwd, flags: agentFlags });
  console.log(`Spawned ${agentType} agent: ${agentId.slice(0, 8)}`);

  if (useTmux) {
    const proc = Bun.spawn({
      cmd: ["tmux", "new-session", "-s", `workforce-${agentId.slice(0, 8)}`, "--", "workforce", "attach", agentId],
      stdio: ["inherit", "inherit", "inherit"],
    });
    await proc.exited;
  } else if (useZellij) {
    const proc = Bun.spawn({
      cmd: ["zellij", "run", "--", "workforce", "attach", agentId],
      stdio: ["inherit", "inherit", "inherit"],
    });
    await proc.exited;
  } else {
    await attachTerminal(client, agentId);
  }
}

async function handleHook(hookName: string, client: DaemonClient) {
  // Read JSON from stdin
  const stdin = await Bun.stdin.text();
  const event = JSON.parse(stdin);

  // Resolve session ID
  const sessionId =
    process.env.WORKFORCE_SESSION ?? event.session_id;

  const now = new Date().toISOString();

  const messageMap: Record<string, any> = {
    "session-start": {
      type: "updateStatus",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      transcript_path: event.transcript_path,
    },
    "session-end": {
      type: "deregister",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
    },
    "pre-tool-use": {
      type: "updateTool",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      tool_name: event.tool_name,
    },
    "post-tool-use": {
      type: "updateTool",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      tool_name: undefined,
    },
    "post-tool-use-failure": {
      type: "updateTool",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      tool_name: undefined,
    },
    notification: {
      type: "notification",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: event.type === "permission_prompt" ? "waitingForPermission" : "waitingForInput",
      notification_type: event.type,
      transcript_path: event.transcript_path,
      notification_message: event.message,
    },
    stop: {
      type: "updateStatus",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "stopped",
    },
    "subagent-start": {
      type: "subagentStart",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      agent_type: event.agent_type,
    },
    "subagent-stop": {
      type: "subagentStop",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      agent_type: event.agent_type,
    },
  };

  const msg = messageMap[hookName];
  if (msg) {
    await client.postEvent(msg);
  }
}

async function daemonStop() {
  const pidPath = join(homedir(), ".workforce", "daemon.pid");
  if (!existsSync(pidPath)) {
    console.log("Daemon not running.");
    return;
  }
  const pid = parseInt(await Bun.file(pidPath).text());
  try {
    process.kill(pid, "SIGTERM");
    console.log("Daemon stopped.");
  } catch {
    console.log("Daemon not running (stale PID).");
  }
}

async function daemonStatus() {
  const pidPath = join(homedir(), ".workforce", "daemon.pid");
  const portPath = join(homedir(), ".workforce", "daemon.port");
  if (!existsSync(pidPath)) {
    console.log("Daemon: not running");
    return;
  }
  const pid = parseInt(await Bun.file(pidPath).text());
  try {
    process.kill(pid, 0);
    const port = await Bun.file(portPath).text();
    console.log(`Daemon: running (PID ${pid}, port ${port.trim()})`);
  } catch {
    console.log("Daemon: not running (stale PID)");
  }
}

async function installLaunchd() {
  const plistPath = join(homedir(), "Library/LaunchAgents/com.workforce.daemon.plist");
  const bunPath = Bun.which("bun") ?? "/usr/local/bin/bun";
  const daemonScript = join(import.meta.dir, "../daemon/index.ts");

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.workforce.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>${bunPath}</string>
        <string>run</string>
        <string>${daemonScript}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${join(homedir(), ".workforce/daemon.stdout.log")}</string>
    <key>StandardErrorPath</key>
    <string>${join(homedir(), ".workforce/daemon.stderr.log")}</string>
</dict>
</plist>`;

  await Bun.write(plistPath, plist);
  const proc = Bun.spawn({ cmd: ["launchctl", "load", plistPath] });
  await proc.exited;
  console.log("Installed and started workforce daemon via launchd.");
}

async function uninstallLaunchd() {
  const plistPath = join(homedir(), "Library/LaunchAgents/com.workforce.daemon.plist");
  if (!existsSync(plistPath)) {
    console.log("Not installed.");
    return;
  }
  const proc = Bun.spawn({ cmd: ["launchctl", "unload", plistPath] });
  await proc.exited;
  const { unlinkSync } = await import("node:fs");
  unlinkSync(plistPath);
  console.log("Uninstalled workforce daemon from launchd.");
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
```

**Step 2: Test manually**

Run: `cd daemon && bun run cli/index.ts daemon start`
Expected: Daemon starts, prints port

Run: `cd daemon && bun run cli/index.ts list`
Expected: "No running agents."

Run: `cd daemon && bun run cli/index.ts daemon stop`
Expected: "Daemon stopped."

**Step 3: Commit**

```bash
git add daemon/cli/index.ts
git commit -m "feat: add CLI with spawn, attach, list, kill, hooks, and daemon management"
```

---

### Task 11: Hook integration test

**Files:**
- Create: `daemon/test/integration.test.ts`

**Step 1: Write integration test**

This test starts the daemon, spawns an agent, sends a hook event, and verifies the state.

```typescript
// daemon/test/integration.test.ts
import { test, expect, beforeAll, afterAll } from "bun:test";
import { mkdirSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";

const TEST_DIR = "/tmp/workforce-integration-test";
let daemonProc: ReturnType<typeof Bun.spawn>;
let port: number;
let token: string;

beforeAll(async () => {
  // Use test-specific workforce dir
  process.env.HOME = TEST_DIR;
  mkdirSync(join(TEST_DIR, ".workforce"), { recursive: true });

  daemonProc = Bun.spawn({
    cmd: ["bun", "run", join(import.meta.dir, "../daemon/index.ts")],
    env: { ...process.env, HOME: TEST_DIR },
  });

  // Wait for daemon to start
  for (let i = 0; i < 50; i++) {
    await Bun.sleep(100);
    const portPath = join(TEST_DIR, ".workforce/daemon.port");
    const tokenPath = join(TEST_DIR, ".workforce/daemon.token");
    if (existsSync(portPath) && existsSync(tokenPath)) {
      port = parseInt(await Bun.file(portPath).text());
      token = (await Bun.file(tokenPath).text()).trim();
      break;
    }
  }
});

afterAll(() => {
  daemonProc?.kill();
  rmSync(TEST_DIR, { recursive: true, force: true });
});

function headers() {
  return {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
  };
}

test("health endpoint returns ok", async () => {
  const res = await fetch(`http://localhost:${port}/api/health`, { headers: headers() });
  const data = await res.json();
  expect(data.ok).toBe(true);
});

test("list agents returns empty array", async () => {
  const res = await fetch(`http://localhost:${port}/api/agents`, { headers: headers() });
  const agents = await res.json();
  expect(agents).toEqual([]);
});

test("spawn agent via API", async () => {
  const res = await fetch(`http://localhost:${port}/api/agents`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({ agentType: "bash", cwd: "/tmp" }),
  });
  const data = await res.json();
  expect(data.agentId).toBeDefined();

  // Verify agent appears in list
  const listRes = await fetch(`http://localhost:${port}/api/agents`, { headers: headers() });
  const agents = await listRes.json();
  expect(agents.length).toBeGreaterThanOrEqual(1);
});

test("post hook event updates agent", async () => {
  // First, get an agent
  const listRes = await fetch(`http://localhost:${port}/api/agents`, { headers: headers() });
  const agents = await listRes.json();
  const agentId = agents[0]?.sessionId;
  if (!agentId) return; // skip if no agent

  const res = await fetch(`http://localhost:${port}/api/events`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({
      type: "updateTool",
      session_id: agentId,
      cwd: "/tmp",
      timestamp: new Date().toISOString(),
      tool_name: "bash",
      status: "active",
    }),
  });
  expect((await res.json()).ok).toBe(true);

  // Verify agent state updated
  const agentRes = await fetch(`http://localhost:${port}/api/agents/${agentId}`, { headers: headers() });
  const agent = await agentRes.json();
  expect(agent.currentToolName).toBe("bash");
});

test("unauthorized request is rejected", async () => {
  const res = await fetch(`http://localhost:${port}/api/agents`, {
    headers: { Authorization: "Bearer wrong-token" },
  });
  expect(res.status).toBe(401);
});

test("kill agent via API", async () => {
  const listRes = await fetch(`http://localhost:${port}/api/agents`, { headers: headers() });
  const agents = await listRes.json();
  const agentId = agents[0]?.sessionId;
  if (!agentId) return;

  const res = await fetch(`http://localhost:${port}/api/agents/${agentId}`, {
    method: "DELETE",
    headers: headers(),
  });
  expect((await res.json()).ok).toBe(true);
});
```

**Step 2: Run integration test**

Run: `cd daemon && bun test test/integration.test.ts --timeout 15000`
Expected: PASS

**Step 3: Commit**

```bash
git add daemon/test/integration.test.ts
git commit -m "test: add integration test for daemon API, spawn, hooks, and auth"
```

---

### Task 12: Package for distribution

**Files:**
- Modify: `daemon/package.json`

**Step 1: Update package.json for npm publishing**

```json
{
  "name": "workforce-cli",
  "version": "0.1.0",
  "type": "module",
  "bin": {
    "workforce": "./cli/index.ts"
  },
  "scripts": {
    "daemon": "bun run daemon/index.ts",
    "test": "bun test",
    "test:unit": "bun test daemon/",
    "test:integration": "bun test test/ --timeout 15000"
  },
  "files": [
    "cli/",
    "daemon/",
    "shared/",
    "test/"
  ],
  "engines": {
    "bun": ">=1.3.5"
  },
  "keywords": ["ai", "agent", "terminal", "pty", "claude"],
  "license": "MIT"
}
```

**Step 2: Verify `bunx` works**

Run: `cd daemon && bun link`
Run: `workforce daemon status`
Expected: "Daemon: not running" or "Daemon: running (...)"

**Step 3: Commit**

```bash
git add daemon/package.json
git commit -m "chore: configure package.json for bunx distribution"
```

---

## Summary

| Task | What | Files |
|------|------|-------|
| 1 | Project setup | `package.json`, `tsconfig.json` |
| 2 | Shared types | `shared/types.ts` |
| 3 | Auth module | `daemon/auth.ts` + test |
| 4 | Agent store | `daemon/agent-store.ts` + test |
| 5 | PTY manager | `daemon/pty-manager.ts` + test |
| 6 | WebSocket hub | `daemon/websocket-hub.ts` + test |
| 7 | Daemon server | `daemon/index.ts` |
| 8 | Daemon client | `cli/daemon-client.ts` |
| 9 | Terminal mode | `cli/terminal.ts` |
| 10 | CLI entry point | `cli/index.ts` |
| 11 | Integration test | `test/integration.test.ts` |
| 12 | Package for distribution | `package.json` update |
