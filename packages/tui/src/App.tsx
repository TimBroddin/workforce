import { useState, useEffect, useRef, useCallback } from "react";
import { Box, useApp, useStdin, useStdout } from "ink";
import { useDaemon } from "./hooks/useDaemon";
import { useTerminal } from "./hooks/useTerminal";
import { useFocus } from "./hooks/useFocus";
import { Sidebar, buildSidebarItems } from "./components/Sidebar";
import { TerminalViewport } from "./components/Terminal";

// Parse basic keypress info from raw stdin chunk
function parseKey(data: string) {
  if (data === "\t") return { name: "tab" } as const;
  if (data === "\r") return { name: "return" } as const;
  if (data === "\x1b[A") return { name: "up" } as const;
  if (data === "\x1b[B") return { name: "down" } as const;
  if (data === "\x1b") return { name: "escape" } as const;
  return { name: "char", char: data } as const;
}

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
  const { internal_eventEmitter, setRawMode } = useStdin() as any;
  const [sidebarIndex, setSidebarIndex] = useState(0);
  const prevAgentIdsRef = useRef<Set<string>>(new Set());

  // Store latest values in refs for the event handler closure
  const stateRef = useRef({
    activePane,
    sidebarIndex,
    items: [] as ReturnType<typeof buildSidebarItems>,
    termCols: 0,
    termRows: 0,
  });

  const items = buildSidebarItems(agents);

  // Terminal dimensions (total minus sidebar width and borders)
  const sidebarWidth = 26; // 24 + 2 border
  const termCols = (stdout?.columns ?? 80) - sidebarWidth - 2;
  const termRows = (stdout?.rows ?? 24) - 2;

  // Keep ref in sync
  stateRef.current = { activePane, sidebarIndex, items, termCols, termRows };

  // Ensure raw mode stays enabled
  useEffect(() => {
    setRawMode(true);
    return () => setRawMode(false);
  }, [setRawMode]);

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

  // Auto-disconnect removed agents
  useEffect(() => {
    const currentIds = new Set(agents.map((a) => a.sessionId));
    for (const prevId of prevAgentIdsRef.current) {
      if (!currentIds.has(prevId)) {
        terminal.disconnect(prevId);
      }
    }
    prevAgentIdsRef.current = currentIds;
  }, [agents, terminal.disconnect]);

  // Auto-select first agent when none is selected
  useEffect(() => {
    if (terminal.activeId === null && agents.length > 0) {
      terminal.select(agents[0].sessionId, termCols, termRows);
    }
  }, [terminal.activeId, agents, termCols, termRows, terminal.select]);

  // Single input handler via Ink's internal event emitter
  // This replaces useInput entirely to avoid double-handling
  const handleInput = useCallback(
    (data: string) => {
      const { activePane, sidebarIndex, items, termCols, termRows } = stateRef.current;
      const key = parseKey(data);

      // Tab always toggles focus
      if (key.name === "tab") {
        toggle();
        return;
      }

      if (activePane === "sidebar") {
        if (key.name === "up") {
          setSidebarIndex((i) => Math.max(0, i - 1));
        } else if (key.name === "down") {
          setSidebarIndex((i) => Math.min(items.length - 1, i + 1));
        } else if (key.name === "return") {
          const item = items[sidebarIndex];
          if (!item) return;
          if (item.type === "agent" && item.agentId) {
            terminal.select(item.agentId, termCols, termRows);
          } else if (item.type === "new") {
            spawnAgent(item.cwd).catch(() => {});
          }
        } else if (key.name === "char" && key.char === "c") {
          const item = items[sidebarIndex];
          if (item) {
            spawnAgent(item.cwd).catch(() => {});
          }
        } else if (key.name === "char" && key.char === "k") {
          const item = items[sidebarIndex];
          if (item?.type === "agent" && item.agentId) {
            killAgent(item.agentId).catch(() => {});
          }
        } else if (key.name === "char" && key.char === "q") {
          terminal.disconnectAll();
          exit();
        }
      } else {
        // Terminal focused — forward raw data to PTY
        terminal.write(data);
      }
    },
    [toggle, terminal, spawnAgent, killAgent, exit]
  );

  useEffect(() => {
    if (!internal_eventEmitter) return;
    internal_eventEmitter.on("input", handleInput);
    return () => {
      internal_eventEmitter.removeListener("input", handleInput);
    };
  }, [internal_eventEmitter, handleInput]);

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
