import { useState, useEffect, useRef, useCallback } from "react";
import { Box, useApp, useStdin, useStdout } from "ink";
import { useDaemon } from "./hooks/useDaemon";
import { useTerminal } from "./hooks/useTerminal";
import { useFocus } from "./hooks/useFocus";
import { Sidebar, buildSidebarItems } from "./components/Sidebar";
import { TerminalViewport } from "./components/Terminal";
import { SpawnModal } from "./components/SpawnModal";
import { isMouseSequence, parseMouseEvent } from "./lib/mouse";
import { groupAgentsByFolder } from "./lib/path-utils";

// Parse basic keypress info from raw stdin chunk
function parseKey(data: string) {
  if (data === "\t") return { name: "tab" } as const;
  if (data === "\r") return { name: "return" } as const;
  if (data === "\x1b[A") return { name: "up" } as const;
  if (data === "\x1b[B") return { name: "down" } as const;
  if (data === "\x1b") return { name: "escape" } as const;
  return { name: "char", char: data } as const;
}

// Build a y-coordinate → sidebar item index map based on the sidebar layout.
// Layout (inside the border, so y starts at 2 for first content row):
//   y=1: top border
//   y=2: "* AgentHub connected"
//   y=3: empty (marginBottom=1)
//   For each folder group:
//     y: folder header ("+ ~/path")
//     y: agent row (one per agent)
//     y: empty (marginBottom=1)
//   ... (rest is spacer + separator + hints)
function buildSidebarYMap(agents: import("shared").Agent[]): Map<number, number> {
  const yMap = new Map<number, number>(); // y → sidebar item index
  const groups = groupAgentsByFolder(agents);
  let y = 4; // row 1=border, 2=header, 3=margin, 4=first group header
  let itemIndex = 0;
  for (const group of groups) {
    y++; // folder header line
    for (const _agent of group.agents) {
      yMap.set(y, itemIndex);
      y++;
      itemIndex++;
    }
    y++; // marginBottom=1
  }
  return yMap;
}

type Mode = "normal" | "spawn";

interface Props {
  port: number;
  token: string;
}

export function App({ port, token }: Props) {
  const config = { port, token };
  const { agents, connected, spawnAgent, killAgent } = useDaemon(config);
  const terminal = useTerminal(config);
  const { activePane, setPane, toggle } = useFocus();
  const { exit } = useApp();
  const { stdout } = useStdout();
  const { internal_eventEmitter, setRawMode } = useStdin() as any;
  const [sidebarIndex, setSidebarIndex] = useState(0);
  const [mode, setMode] = useState<Mode>("normal");
  const [spawnIndex, setSpawnIndex] = useState(0);
  const prevAgentIdsRef = useRef<Set<string>>(new Set());

  const items = buildSidebarItems(agents);

  // Unique folders from current agents + cwd as fallback
  const folders = [...new Set(agents.map((a) => a.cwd))];
  if (folders.length === 0) {
    folders.push(process.cwd());
  }

  // Terminal dimensions (total minus sidebar width and borders)
  const sidebarWidth = 34; // 32 content + 2 border
  const termBorder = 2;    // terminal box left + right border
  const termCols = Math.max(1, (stdout?.columns ?? 80) - sidebarWidth - termBorder);
  const termRows = Math.max(1, (stdout?.rows ?? 24) - termBorder);

  // Store latest values in refs for the event handler closure
  const stateRef = useRef({
    activePane,
    sidebarIndex,
    items,
    termCols,
    termRows,
    mode,
    spawnIndex,
    folders,
    agents,
  });
  stateRef.current = { activePane, sidebarIndex, items, termCols, termRows, mode, spawnIndex, folders, agents };

  // Enable mouse tracking + raw mode
  useEffect(() => {
    setRawMode(true);
    // Enable SGR extended mouse mode + basic mouse mode
    process.stdout.write("\x1b[?1000h\x1b[?1006h");
    return () => {
      process.stdout.write("\x1b[?1000l\x1b[?1006l");
      setRawMode(false);
    };
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

  const handleInput = useCallback(
    (data: string) => {
      const s = stateRef.current;

      // Intercept mouse events — never forward to PTY
      if (isMouseSequence(data)) {
        const mouse = parseMouseEvent(data);
        if (!mouse || mouse.button === "release") return;

        // Click in sidebar area?
        if (mouse.x <= sidebarWidth) {
          if (mouse.button === "left") {
            setPane("sidebar");
            // Try to map click y to a sidebar agent item
            const yMap = buildSidebarYMap(s.agents);
            const idx = yMap.get(mouse.y);
            if (idx !== undefined && idx < s.items.length) {
              setSidebarIndex(idx);
              const item = s.items[idx];
              if (item) {
                terminal.select(item.agentId, s.termCols, s.termRows);
              }
            }
          } else if (mouse.button === "wheel-up") {
            setSidebarIndex((i) => Math.max(0, i - 1));
          } else if (mouse.button === "wheel-down") {
            setSidebarIndex((i) => Math.min(s.items.length - 1, i + 1));
          }
        } else {
          // Click/scroll in terminal area
          if (mouse.button === "left") {
            setPane("terminal");
          } else if (mouse.button === "wheel-up") {
            terminal.scrollUp();
          } else if (mouse.button === "wheel-down") {
            terminal.scrollDown();
          }
        }
        return;
      }

      const key = parseKey(data);

      // Spawn modal mode
      if (s.mode === "spawn") {
        if (key.name === "escape") {
          setMode("normal");
        } else if (key.name === "up") {
          setSpawnIndex((i) => Math.max(0, i - 1));
        } else if (key.name === "down") {
          setSpawnIndex((i) => Math.min(s.folders.length - 1, i + 1));
        } else if (key.name === "return") {
          const folder = s.folders[s.spawnIndex];
          if (folder) {
            spawnAgent(folder).catch(() => {});
          }
          setMode("normal");
        }
        return;
      }

      // Normal mode — Tab always toggles focus
      if (key.name === "tab") {
        toggle();
        return;
      }

      if (s.activePane === "sidebar") {
        if (key.name === "up") {
          setSidebarIndex((i) => Math.max(0, i - 1));
        } else if (key.name === "down") {
          setSidebarIndex((i) => Math.min(s.items.length - 1, i + 1));
        } else if (key.name === "return") {
          const item = s.items[s.sidebarIndex];
          if (item) {
            terminal.select(item.agentId, s.termCols, s.termRows);
          }
        } else if (key.name === "char" && key.char === "n") {
          setSpawnIndex(0);
          setMode("spawn");
        } else if (key.name === "char" && key.char === "k") {
          const item = s.items[s.sidebarIndex];
          if (item) {
            killAgent(item.agentId).catch(() => {});
          }
        } else if (key.name === "char" && key.char === "x") {
          const item = s.items[s.sidebarIndex];
          if (item) {
            terminal.disconnect(item.agentId);
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
    [toggle, setPane, terminal, spawnAgent, killAgent, exit]
  );

  useEffect(() => {
    if (!internal_eventEmitter) return;
    internal_eventEmitter.on("input", handleInput);
    return () => {
      internal_eventEmitter.removeListener("input", handleInput);
    };
  }, [internal_eventEmitter, handleInput]);

  return (
    <Box flexDirection="row" width="100%" height={stdout?.rows ?? 24}>
      <Sidebar
        agents={agents}
        selectedIndex={sidebarIndex}
        focused={activePane === "sidebar" && mode === "normal"}
        connected={connected}
      />
      {mode === "spawn" ? (
        <Box flexGrow={1} justifyContent="center" alignItems="center">
          <SpawnModal folders={folders} selectedIndex={spawnIndex} />
        </Box>
      ) : (
        <TerminalViewport
          lines={terminal.lines}
          focused={activePane === "terminal"}
          scrollOffset={terminal.scrollOffset}
        />
      )}
    </Box>
  );
}
