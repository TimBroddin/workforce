import { useState, useEffect, useRef } from "react";
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
  const prevAgentIdsRef = useRef<Set<string>>(new Set());

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

  // useInput is only active when sidebar is focused (isActive option)
  // When terminal is focused, raw stdin forwarding handles all input
  useInput((input, key) => {
    if (key.tab) {
      toggle();
      return;
    }
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
  }, { isActive: activePane === "sidebar" });

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
