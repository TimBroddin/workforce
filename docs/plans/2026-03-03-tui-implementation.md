# TUI Package Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `packages/tui` package that provides a tmux-like terminal UI for switching between agent sessions, using Ink (React) with embedded terminal rendering via `@xterm/headless`.

**Architecture:** Ink app with two panes — a left sidebar showing agents grouped by folder, and a right terminal viewport rendering the selected agent's PTY output via `@xterm/headless`. Connects to the running agenthub daemon via HTTP and WebSocket APIs. Tab key toggles focus between sidebar and terminal.

**Tech Stack:** Ink, React, @xterm/headless, WebSocket (native), @workforce/shared types

---

### Task 1: Scaffold the `packages/tui` package

**Files:**
- Create: `packages/tui/package.json`
- Modify: `package.json:3` (add workspace)

**Step 1: Create `packages/tui/package.json`**

```json
{
  "name": "@timbroddin/agenthub-tui",
  "version": "0.3.0",
  "private": true,
  "type": "module",
  "dependencies": {
    "shared": "workspace:*",
    "ink": "^5.1.0",
    "react": "^18.3.1",
    "@xterm/headless": "^6.0.0"
  },
  "devDependencies": {
    "@types/react": "^18.3.0"
  }
}
```

**Step 2: Add workspace to root `package.json`**

Change line 3 from:
```json
"workspaces": ["packages/shared", "packages/cli"],
```
to:
```json
"workspaces": ["packages/shared", "packages/cli", "packages/tui"],
```

**Step 3: Install dependencies**

Run: `cd /Users/timbroddin/Projects/workforce && bun install`
Expected: Dependencies resolve, no errors.

**Step 4: Commit**

```bash
git add packages/tui/package.json package.json bun.lockb
git commit -m "feat(tui): scaffold packages/tui with ink and xterm/headless"
```

---

### Task 2: Path utilities and focus hook

**Files:**
- Create: `packages/tui/src/lib/path-utils.ts`
- Create: `packages/tui/src/hooks/useFocus.ts`

**Step 1: Write path-utils test**

Create: `packages/tui/test/path-utils.test.ts`

```ts
import { test, expect } from "bun:test";
import { shortenPath, groupAgentsByFolder } from "../src/lib/path-utils";
import type { Agent } from "shared";

test("shortenPath replaces homedir with ~", () => {
  const home = process.env.HOME ?? "/Users/test";
  expect(shortenPath(`${home}/Projects/app`)).toBe("~/Projects/app");
});

test("shortenPath returns path unchanged if not under home", () => {
  expect(shortenPath("/tmp/something")).toBe("/tmp/something");
});

test("groupAgentsByFolder groups agents by cwd", () => {
  const agents = [
    { sessionId: "a", cwd: "/home/user/app" },
    { sessionId: "b", cwd: "/home/user/app" },
    { sessionId: "c", cwd: "/home/user/api" },
  ] as Agent[];

  const groups = groupAgentsByFolder(agents);
  expect(groups).toHaveLength(2);
  expect(groups[0].cwd).toBe("/home/user/app");
  expect(groups[0].agents).toHaveLength(2);
  expect(groups[1].cwd).toBe("/home/user/api");
  expect(groups[1].agents).toHaveLength(1);
});
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/timbroddin/Projects/workforce && bun test packages/tui/test/path-utils.test.ts`
Expected: FAIL — module not found

**Step 3: Implement path-utils**

Create: `packages/tui/src/lib/path-utils.ts`

```ts
import { homedir } from "node:os";
import type { Agent } from "shared";

export function shortenPath(path: string): string {
  const home = homedir();
  if (path.startsWith(home)) {
    return "~" + path.slice(home.length);
  }
  return path;
}

export interface FolderGroup {
  cwd: string;
  agents: Agent[];
}

export function groupAgentsByFolder(agents: Agent[]): FolderGroup[] {
  const map = new Map<string, Agent[]>();
  for (const agent of agents) {
    const list = map.get(agent.cwd) ?? [];
    list.push(agent);
    map.set(agent.cwd, list);
  }
  return Array.from(map.entries()).map(([cwd, agents]) => ({ cwd, agents }));
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/timbroddin/Projects/workforce && bun test packages/tui/test/path-utils.test.ts`
Expected: PASS

**Step 5: Create useFocus hook**

Create: `packages/tui/src/hooks/useFocus.ts`

```ts
import { useState, useCallback } from "react";

export type Pane = "sidebar" | "terminal";

export function useFocus() {
  const [activePane, setActivePane] = useState<Pane>("sidebar");

  const toggle = useCallback(() => {
    setActivePane((prev) => (prev === "sidebar" ? "terminal" : "sidebar"));
  }, []);

  return { activePane, toggle };
}
```

**Step 6: Commit**

```bash
git add packages/tui/src/lib/path-utils.ts packages/tui/src/hooks/useFocus.ts packages/tui/test/path-utils.test.ts
git commit -m "feat(tui): add path utilities and focus hook"
```

---

### Task 3: Daemon connection hook (`useDaemon`)

**Files:**
- Create: `packages/tui/src/hooks/useDaemon.ts`

**Step 1: Implement useDaemon hook**

This hook connects to the daemon's control WebSocket and maintains the agent list.

Create: `packages/tui/src/hooks/useDaemon.ts`

```ts
import { useState, useEffect, useRef, useCallback } from "react";
import type { Agent, DaemonControlMessage } from "shared";

interface DaemonConfig {
  port: number;
  token: string;
}

export function useDaemon(config: DaemonConfig) {
  const [agents, setAgents] = useState<Agent[]>([]);
  const [connected, setConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    const url = `ws://localhost:${config.port}/ws/control?token=${config.token}`;
    const ws = new WebSocket(url);
    wsRef.current = ws;

    ws.onopen = () => {
      setConnected(true);
      ws.send(JSON.stringify({ type: "snapshot" }));
    };

    ws.onmessage = (event) => {
      const msg: DaemonControlMessage = JSON.parse(String(event.data));
      if (msg.type === "agents") {
        setAgents(msg.agents);
      } else if (msg.type === "event") {
        // Request fresh snapshot on any event
        ws.send(JSON.stringify({ type: "snapshot" }));
      }
    };

    ws.onclose = () => setConnected(false);
    ws.onerror = () => setConnected(false);

    return () => {
      ws.close();
    };
  }, [config.port, config.token]);

  const spawnAgent = useCallback(
    async (cwd: string, agentType = "claude") => {
      const res = await fetch(`http://localhost:${config.port}/api/agents`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${config.token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ agentType, cwd }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error);
      return data.agentId as string;
    },
    [config.port, config.token]
  );

  const killAgent = useCallback(
    async (id: string) => {
      await fetch(`http://localhost:${config.port}/api/agents/${id}`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${config.token}` },
      });
    },
    [config.port, config.token]
  );

  return { agents, connected, spawnAgent, killAgent };
}
```

**Step 2: Commit**

```bash
git add packages/tui/src/hooks/useDaemon.ts
git commit -m "feat(tui): add useDaemon hook for agent list and control"
```

---

### Task 4: Terminal hook (`useTerminal`) with `@xterm/headless`

**Files:**
- Create: `packages/tui/src/hooks/useTerminal.ts`
- Create: `packages/tui/src/lib/xterm-ink.ts`

**Step 1: Implement xterm-ink buffer renderer**

This converts `@xterm/headless` buffer rows into plain text lines with ANSI color attributes preserved as escape codes. Ink's `<Text>` can render raw ANSI.

Create: `packages/tui/src/lib/xterm-ink.ts`

```ts
import type { IBufferCell, Terminal } from "@xterm/headless";

/**
 * Extract visible lines from an xterm buffer as strings with ANSI escapes.
 * Returns an array of strings, one per row, for the visible viewport.
 */
export function extractBufferLines(terminal: Terminal, rows: number, cols: number): string[] {
  const buffer = terminal.buffer.active;
  const lines: string[] = [];

  for (let y = 0; y < rows; y++) {
    const line = buffer.getLine(y + buffer.viewportY);
    if (!line) {
      lines.push("");
      continue;
    }

    let str = "";
    let prevFg = -1;
    let prevBg = -1;
    let prevBold = false;
    let prevItalic = false;
    let prevUnderline = false;

    const cell: IBufferCell = line.getCell(0)!;

    for (let x = 0; x < cols; x++) {
      line.getCell(x, cell);
      if (!cell) {
        str += " ";
        continue;
      }

      const fg = cell.getFgColor();
      const bg = cell.getBgColor();
      const bold = cell.isBold() !== 0;
      const italic = cell.isItalic() !== 0;
      const underline = cell.isUnderline() !== 0;

      // Emit ANSI reset + new attributes when they change
      if (fg !== prevFg || bg !== prevBg || bold !== prevBold || italic !== prevItalic || underline !== prevUnderline) {
        const codes: number[] = [0]; // reset
        if (bold) codes.push(1);
        if (italic) codes.push(3);
        if (underline) codes.push(4);

        const fgColorMode = cell.getFgColorMode();
        if (fgColorMode === 1) {
          // 16-color
          codes.push(fg < 8 ? 30 + fg : 90 + (fg - 8));
        } else if (fgColorMode === 2) {
          // 256-color
          codes.push(38, 5, fg);
        } else if (fgColorMode === 3) {
          // truecolor
          codes.push(38, 2, (fg >> 16) & 0xff, (fg >> 8) & 0xff, fg & 0xff);
        }

        const bgColorMode = cell.getBgColorMode();
        if (bgColorMode === 1) {
          codes.push(bg < 8 ? 40 + bg : 100 + (bg - 8));
        } else if (bgColorMode === 2) {
          codes.push(48, 5, bg);
        } else if (bgColorMode === 3) {
          codes.push(48, 2, (bg >> 16) & 0xff, (bg >> 8) & 0xff, bg & 0xff);
        }

        str += `\x1b[${codes.join(";")}m`;
        prevFg = fg;
        prevBg = bg;
        prevBold = bold;
        prevItalic = italic;
        prevUnderline = underline;
      }

      str += cell.getChars() || " ";
    }

    str += "\x1b[0m"; // reset at end of line
    lines.push(str);
  }

  return lines;
}
```

**Step 2: Implement useTerminal hook**

Create: `packages/tui/src/hooks/useTerminal.ts`

```ts
import { useState, useEffect, useRef, useCallback } from "react";
import { Terminal } from "@xterm/headless";
import { extractBufferLines } from "../lib/xterm-ink";

interface TerminalConfig {
  port: number;
  token: string;
}

interface TerminalSession {
  terminal: Terminal;
  ws: WebSocket;
  lines: string[];
}

export function useTerminal(config: TerminalConfig) {
  const sessionsRef = useRef<Map<string, TerminalSession>>(new Map());
  const [lines, setLines] = useState<string[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const renderTimer = useRef<ReturnType<typeof setInterval> | null>(null);

  // Render the active terminal's buffer at ~15fps
  useEffect(() => {
    renderTimer.current = setInterval(() => {
      if (!activeId) return;
      const session = sessionsRef.current.get(activeId);
      if (!session) return;
      const newLines = extractBufferLines(session.terminal, session.terminal.rows, session.terminal.cols);
      setLines(newLines);
    }, 66);

    return () => {
      if (renderTimer.current) clearInterval(renderTimer.current);
    };
  }, [activeId]);

  const connect = useCallback(
    (agentId: string, cols: number, rows: number) => {
      if (sessionsRef.current.has(agentId)) return;

      const terminal = new Terminal({ cols, rows, allowProposedApi: true });
      const url = `ws://localhost:${config.port}/ws/terminal/${agentId}?token=${config.token}&cols=${cols}&rows=${rows}`;
      const ws = new WebSocket(url);
      ws.binaryType = "arraybuffer";

      const session: TerminalSession = { terminal, ws, lines: [] };

      ws.onmessage = (event) => {
        if (event.data instanceof ArrayBuffer) {
          terminal.write(new Uint8Array(event.data));
        }
      };

      ws.onclose = () => {
        sessionsRef.current.delete(agentId);
      };

      sessionsRef.current.set(agentId, session);
    },
    [config.port, config.token]
  );

  const disconnect = useCallback((agentId: string) => {
    const session = sessionsRef.current.get(agentId);
    if (session) {
      session.ws.close();
      session.terminal.dispose();
      sessionsRef.current.delete(agentId);
    }
  }, []);

  const select = useCallback(
    (agentId: string, cols: number, rows: number) => {
      if (!sessionsRef.current.has(agentId)) {
        connect(agentId, cols, rows);
      }
      setActiveId(agentId);
    },
    [connect]
  );

  const write = useCallback(
    (data: string | Uint8Array) => {
      if (!activeId) return;
      const session = sessionsRef.current.get(activeId);
      if (session && session.ws.readyState === WebSocket.OPEN) {
        session.ws.send(data);
      }
    },
    [activeId]
  );

  const resize = useCallback(
    (agentId: string, cols: number, rows: number) => {
      const session = sessionsRef.current.get(agentId);
      if (session) {
        session.terminal.resize(cols, rows);
        if (session.ws.readyState === WebSocket.OPEN) {
          session.ws.send(JSON.stringify({ type: "resize", cols, rows }));
        }
      }
    },
    []
  );

  const disconnectAll = useCallback(() => {
    for (const [id] of sessionsRef.current) {
      disconnect(id);
    }
  }, [disconnect]);

  return { lines, activeId, select, write, resize, connect, disconnect, disconnectAll };
}
```

**Step 3: Commit**

```bash
git add packages/tui/src/lib/xterm-ink.ts packages/tui/src/hooks/useTerminal.ts
git commit -m "feat(tui): add xterm/headless terminal hook and buffer renderer"
```

---

### Task 5: Sidebar components

**Files:**
- Create: `packages/tui/src/components/AgentRow.tsx`
- Create: `packages/tui/src/components/FolderGroup.tsx`
- Create: `packages/tui/src/components/Sidebar.tsx`

**Step 1: Create AgentRow component**

Create: `packages/tui/src/components/AgentRow.tsx`

```tsx
import React from "react";
import { Text } from "ink";
import type { Agent, AgentStatus } from "shared";

const STATUS_ICONS: Record<AgentStatus, string> = {
  active: "●",
  idle: "○",
  waitingForInput: "◐",
  waitingForPermission: "◐",
  stopped: "✕",
  orphaned: "?",
};

const STATUS_COLORS: Record<AgentStatus, string> = {
  active: "green",
  idle: "gray",
  waitingForInput: "yellow",
  waitingForPermission: "yellow",
  stopped: "red",
  orphaned: "magenta",
};

interface Props {
  agent: Agent;
  selected: boolean;
}

export function AgentRow({ agent, selected }: Props) {
  const icon = STATUS_ICONS[agent.status] ?? "?";
  const color = STATUS_COLORS[agent.status] ?? "white";

  return (
    <Text
      backgroundColor={selected ? "blue" : undefined}
      color={selected ? "white" : undefined}
    >
      {"  "}
      <Text color={color}>{icon}</Text>
      {" "}
      {agent.name}
    </Text>
  );
}
```

**Step 2: Create FolderGroup component**

Create: `packages/tui/src/components/FolderGroup.tsx`

```tsx
import React from "react";
import { Box, Text } from "ink";
import type { Agent } from "shared";
import { AgentRow } from "./AgentRow";
import { shortenPath } from "../lib/path-utils";

interface Props {
  cwd: string;
  agents: Agent[];
  selectedId: string | null;
  showNewButton: boolean;
  newSelected: boolean;
}

export function FolderGroup({ cwd, agents, selectedId, showNewButton, newSelected }: Props) {
  return (
    <Box flexDirection="column">
      <Text bold dimColor>
        {shortenPath(cwd)}
      </Text>
      {agents.map((agent) => (
        <AgentRow
          key={agent.sessionId}
          agent={agent}
          selected={agent.sessionId === selectedId}
        />
      ))}
      {showNewButton && (
        <Text
          backgroundColor={newSelected ? "blue" : undefined}
          color={newSelected ? "white" : "gray"}
        >
          {"  [+] New"}
        </Text>
      )}
    </Box>
  );
}
```

**Step 3: Create Sidebar component**

Create: `packages/tui/src/components/Sidebar.tsx`

```tsx
import React from "react";
import { Box, Text } from "ink";
import type { Agent } from "shared";
import { FolderGroup } from "./FolderGroup";
import { groupAgentsByFolder } from "../lib/path-utils";

interface SidebarItem {
  type: "agent" | "new";
  agentId?: string;
  cwd: string;
}

export function buildSidebarItems(agents: Agent[]): SidebarItem[] {
  const groups = groupAgentsByFolder(agents);
  const items: SidebarItem[] = [];
  for (const group of groups) {
    for (const agent of group.agents) {
      items.push({ type: "agent", agentId: agent.sessionId, cwd: group.cwd });
    }
    items.push({ type: "new", cwd: group.cwd });
  }
  return items;
}

interface Props {
  agents: Agent[];
  selectedIndex: number;
  focused: boolean;
  connected: boolean;
}

export function Sidebar({ agents, selectedIndex, focused, connected }: Props) {
  const items = buildSidebarItems(agents);
  const groups = groupAgentsByFolder(agents);

  let itemIndex = 0;

  return (
    <Box
      flexDirection="column"
      width={24}
      borderStyle={focused ? "bold" : "single"}
      borderColor={focused ? "blue" : "gray"}
      paddingX={1}
    >
      <Text bold>
        AgentHub {connected ? <Text color="green">●</Text> : <Text color="red">●</Text>}
      </Text>
      <Text> </Text>
      {groups.map((group) => {
        const startIndex = itemIndex;
        const agentIds = group.agents.map((a) => a.sessionId);
        const selectedItem = items[selectedIndex];

        const result = (
          <FolderGroup
            key={group.cwd}
            cwd={group.cwd}
            agents={group.agents}
            selectedId={
              selectedItem?.type === "agent" && agentIds.includes(selectedItem.agentId!)
                ? selectedItem.agentId!
                : null
            }
            showNewButton={true}
            newSelected={
              selectedItem?.type === "new" && selectedItem.cwd === group.cwd
            }
          />
        );

        itemIndex += group.agents.length + 1; // agents + [+] New
        return result;
      })}
      {agents.length === 0 && (
        <Text dimColor>No agents running</Text>
      )}
    </Box>
  );
}
```

**Step 4: Commit**

```bash
git add packages/tui/src/components/AgentRow.tsx packages/tui/src/components/FolderGroup.tsx packages/tui/src/components/Sidebar.tsx
git commit -m "feat(tui): add sidebar components (AgentRow, FolderGroup, Sidebar)"
```

---

### Task 6: Terminal viewport component

**Files:**
- Create: `packages/tui/src/components/Terminal.tsx`

**Step 1: Create Terminal viewport component**

Create: `packages/tui/src/components/Terminal.tsx`

```tsx
import React from "react";
import { Box, Text } from "ink";

interface Props {
  lines: string[];
  focused: boolean;
}

export function TerminalViewport({ lines, focused }: Props) {
  return (
    <Box
      flexDirection="column"
      flexGrow={1}
      borderStyle={focused ? "bold" : "single"}
      borderColor={focused ? "green" : "gray"}
    >
      {lines.length === 0 ? (
        <Text dimColor>Select an agent to view terminal output</Text>
      ) : (
        lines.map((line, i) => (
          <Text key={i}>{line}</Text>
        ))
      )}
    </Box>
  );
}
```

**Step 2: Commit**

```bash
git add packages/tui/src/components/Terminal.tsx
git commit -m "feat(tui): add terminal viewport component"
```

---

### Task 7: App root component and entry point

**Files:**
- Create: `packages/tui/src/App.tsx`
- Create: `packages/tui/src/index.tsx`

**Step 1: Create App component**

This is the root that wires everything together: daemon hook, terminal hook, focus management, and keyboard input.

Create: `packages/tui/src/App.tsx`

```tsx
import React, { useState, useCallback, useEffect } from "react";
import { Box, useApp, useInput, useStdout } from "ink";
import { useDaemon } from "./hooks/useDaemon";
import { useTerminal } from "./hooks/useTerminal";
import { useFocus } from "./hooks/useFocus";
import { Sidebar, buildSidebarItems } from "./components/Sidebar";
import { TerminalViewport } from "./components/Terminal";

interface Props {
  port: number;
  token: string;
}

export function App({ port, token }: Props) {
  const config = { port, token };
  const { agents, connected, spawnAgent, killAgent } = useDaemon(config);
  const terminal = useTerminal(config);
  const { activePane, toggle } = useFocus();
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [sidebarIndex, setSidebarIndex] = useState(0);

  const items = buildSidebarItems(agents);

  // Terminal dimensions (total minus sidebar width and borders)
  const sidebarWidth = 26; // 24 + 2 border
  const termCols = (stdout?.columns ?? 80) - sidebarWidth - 2; // 2 for terminal border
  const termRows = (stdout?.rows ?? 24) - 2; // 2 for terminal border

  // Keep sidebar index in bounds
  useEffect(() => {
    if (sidebarIndex >= items.length && items.length > 0) {
      setSidebarIndex(items.length - 1);
    }
  }, [items.length, sidebarIndex]);

  // Handle resize for active terminal
  useEffect(() => {
    if (terminal.activeId) {
      terminal.resize(terminal.activeId, termCols, termRows);
    }
  }, [termCols, termRows, terminal.activeId]);

  useInput((input, key) => {
    // Tab toggles focus
    if (key.tab) {
      toggle();
      return;
    }

    if (activePane === "sidebar") {
      if (key.upArrow) {
        setSidebarIndex((i) => Math.max(0, i - 1));
      } else if (key.downArrow) {
        setSidebarIndex((i) => Math.min(items.length - 1, i + 1));
      } else if (key.return) {
        const item = items[sidebarIndex];
        if (!item) return;
        if (item.type === "agent" && item.agentId) {
          terminal.select(item.agentId, termCols, termRows);
        } else if (item.type === "new") {
          spawnAgent(item.cwd).catch(() => {});
        }
      } else if (input === "c") {
        const item = items[sidebarIndex];
        if (item) {
          spawnAgent(item.cwd).catch(() => {});
        }
      } else if (input === "k") {
        const item = items[sidebarIndex];
        if (item?.type === "agent" && item.agentId) {
          killAgent(item.agentId).catch(() => {});
        }
      } else if (input === "q") {
        terminal.disconnectAll();
        exit();
      }
    } else {
      // Terminal focused — forward input to PTY
      if (key.escape) {
        // noop — let escape through to agent
      }
      // Ink's useInput doesn't give raw bytes for terminal forwarding.
      // We need raw stdin mode for the terminal pane.
      // This will be handled by the raw stdin forwarder below.
    }
  });

  // Raw stdin forwarding when terminal is focused
  useEffect(() => {
    if (activePane !== "terminal") return;

    const onData = (data: Buffer) => {
      // Check for tab key (0x09) to toggle back
      if (data.length === 1 && data[0] === 0x09) {
        toggle();
        return;
      }
      terminal.write(data);
    };

    if (process.stdin.isTTY) {
      process.stdin.setRawMode(true);
    }
    process.stdin.on("data", onData);

    return () => {
      process.stdin.removeListener("data", onData);
    };
  }, [activePane, terminal.write, toggle]);

  return (
    <Box flexDirection="row" width="100%" height="100%">
      <Sidebar
        agents={agents}
        selectedIndex={sidebarIndex}
        focused={activePane === "sidebar"}
        connected={connected}
      />
      <TerminalViewport
        lines={terminal.lines}
        focused={activePane === "terminal"}
      />
    </Box>
  );
}
```

**Step 2: Create entry point**

Create: `packages/tui/src/index.tsx`

```tsx
import React from "react";
import { render } from "ink";
import { App } from "./App";

export interface TuiOptions {
  port: number;
  token: string;
}

export function startTui(options: TuiOptions) {
  const { waitUntilExit } = render(
    <App port={options.port} token={options.token} />,
    { exitOnCtrlC: false }
  );
  return waitUntilExit;
}
```

**Step 3: Commit**

```bash
git add packages/tui/src/App.tsx packages/tui/src/index.tsx
git commit -m "feat(tui): add App root component and entry point"
```

---

### Task 8: Wire `agenthub tui` command into CLI

**Files:**
- Modify: `packages/cli/src/index.ts`
- Modify: `packages/cli/package.json` (add tui dependency)

**Step 1: Add tui dependency to CLI package.json**

In `packages/cli/package.json`, change:
```json
"dependencies": {
  "shared": "workspace:*"
},
```
to:
```json
"dependencies": {
  "shared": "workspace:*",
  "@timbroddin/agenthub-tui": "workspace:*"
},
```

**Step 2: Add `tui` command to CLI index.ts**

In `packages/cli/src/index.ts`, add the `tui` command after the `"install-hooks"` / `"uninstall-hooks"` block and before the `knownCommands` validation.

After line 115 (end of uninstall-hooks block), add:

```ts
  if (command === "tui") {
    const { port, token } = await ensureDaemon();
    const { startTui } = await import("@timbroddin/agenthub-tui");
    const waitUntilExit = startTui({ port, token });
    await waitUntilExit();
    return;
  }
```

Also add `"tui"` to the `knownCommands` array.

Update the help text to include the `tui` command:
```
  tui                    Interactive terminal UI
```

**Step 3: Run `bun install` to link the workspace dependency**

Run: `cd /Users/timbroddin/Projects/workforce && bun install`

**Step 4: Test manually**

Run: `cd /Users/timbroddin/Projects/workforce && bun run packages/cli/src/index.ts tui`
Expected: TUI launches showing connected sidebar. Ctrl+C or `q` exits.

**Step 5: Commit**

```bash
git add packages/cli/src/index.ts packages/cli/package.json bun.lockb
git commit -m "feat(cli): add 'agenthub tui' command"
```

---

### Task 9: Handle raw stdin conflict between Ink and terminal pane

**Files:**
- Modify: `packages/tui/src/App.tsx`

**Context:** Ink uses `useInput` which assumes control of stdin. When the terminal pane is focused, we need raw bytes forwarded to the PTY. This task resolves the conflict — Ink's `useInput` should be disabled when terminal is focused, and raw stdin should be forwarded directly.

**Step 1: Refactor App to use raw stdin mode when terminal focused**

Update `packages/tui/src/App.tsx` — the `useInput` hook should only process input when the sidebar is focused. When terminal is focused, `useInput` should be a no-op and raw stdin forwarding takes over.

The key insight: Ink's `useInput` already works in raw mode. We need to intercept at a lower level. Update the `useInput` callback to check `activePane` and short-circuit for terminal mode (only handling Tab). The raw stdin `useEffect` from Task 7 handles the rest.

**Step 2: Test manually**

Run: `bun run packages/cli/src/index.ts tui`
Expected: Can switch between sidebar and terminal with Tab. When terminal focused, typing sends to agent PTY. When sidebar focused, arrow keys navigate.

**Step 3: Commit**

```bash
git add packages/tui/src/App.tsx
git commit -m "fix(tui): resolve stdin conflict between Ink and terminal pane"
```

---

### Task 10: Cleanup disconnected agents and handle edge cases

**Files:**
- Modify: `packages/tui/src/hooks/useTerminal.ts`
- Modify: `packages/tui/src/App.tsx`

**Step 1: Auto-disconnect removed agents**

In `useDaemon`, when an agent disappears from the list (deregistered), the terminal hook should disconnect its WebSocket. Add an effect in `App.tsx` that watches the agent list and calls `terminal.disconnect()` for agents no longer present.

**Step 2: Auto-select first agent**

When the TUI launches with agents already running, auto-select the first one.

**Step 3: Handle empty state**

When no agents are running, show a helpful message in the terminal viewport: "No agents running. Press 'c' in sidebar to spawn one, or run 'agenthub claude' in another terminal."

**Step 4: Test manually**

Run: `bun run packages/cli/src/index.ts tui`
Expected:
- Agents that stop disappear from sidebar
- First agent auto-selected on launch
- Empty state shows help text

**Step 5: Commit**

```bash
git add packages/tui/src/hooks/useTerminal.ts packages/tui/src/App.tsx
git commit -m "feat(tui): handle agent lifecycle and empty state"
```

---

### Summary

| Task | Description | Key Files |
|------|-------------|-----------|
| 1 | Scaffold package | `packages/tui/package.json`, root `package.json` |
| 2 | Path utils + focus hook | `path-utils.ts`, `useFocus.ts` |
| 3 | Daemon connection hook | `useDaemon.ts` |
| 4 | Terminal hook + xterm renderer | `useTerminal.ts`, `xterm-ink.ts` |
| 5 | Sidebar components | `AgentRow.tsx`, `FolderGroup.tsx`, `Sidebar.tsx` |
| 6 | Terminal viewport component | `Terminal.tsx` |
| 7 | App root + entry point | `App.tsx`, `index.tsx` |
| 8 | Wire CLI command | `packages/cli/src/index.ts` |
| 9 | Raw stdin handling | `App.tsx` refinement |
| 10 | Edge cases + polish | Lifecycle, empty state |
