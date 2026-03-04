import { useState, useEffect, useRef, useCallback } from "react";
import { Terminal } from "@xterm/headless";
import { extractBufferLines, getBufferLength } from "../lib/xterm-ink";

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
  const [scrollOffset, setScrollOffset] = useState(0);
  const scrollOffsetRef = useRef(0);
  const renderTimer = useRef<ReturnType<typeof setInterval> | null>(null);

  // Keep ref in sync for the render interval
  scrollOffsetRef.current = scrollOffset;

  // Render the active terminal's buffer at ~15fps
  useEffect(() => {
    renderTimer.current = setInterval(() => {
      if (!activeId) return;
      const session = sessionsRef.current.get(activeId);
      if (!session) return;
      const newLines = extractBufferLines(
        session.terminal,
        session.terminal.rows,
        session.terminal.cols,
        scrollOffsetRef.current,
      );
      setLines(newLines);
    }, 66);

    return () => {
      if (renderTimer.current) clearInterval(renderTimer.current);
    };
  }, [activeId]);

  const connect = useCallback(
    (agentId: string, cols: number, rows: number) => {
      if (sessionsRef.current.has(agentId)) return;

      const terminal = new Terminal({ cols, rows, scrollback: 5000, allowProposedApi: true });
      const url = `ws://localhost:${config.port}/ws/terminal/${agentId}?token=${config.token}&cols=${cols}&rows=${rows}`;
      const ws = new WebSocket(url);
      ws.binaryType = "arraybuffer";

      const session: TerminalSession = { terminal, ws, lines: [] };

      ws.onmessage = (event) => {
        if (event.data instanceof ArrayBuffer) {
          terminal.write(new Uint8Array(event.data));
          // Auto-snap to bottom when new output arrives and we're scrolled back
          if (scrollOffsetRef.current > 0) {
            // Only auto-snap if we're near the bottom (within 3 lines)
            if (scrollOffsetRef.current <= 3) {
              setScrollOffset(0);
            }
          }
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
      setScrollOffset(0); // Reset scroll when switching agents
    },
    [connect]
  );

  const write = useCallback(
    (data: string | Uint8Array) => {
      if (!activeId) return;
      const session = sessionsRef.current.get(activeId);
      if (session && session.ws.readyState === WebSocket.OPEN) {
        // Always send as binary — the daemon treats text frames as JSON control messages
        const binary = typeof data === "string" ? new TextEncoder().encode(data) : data;
        session.ws.send(binary);
      }
      // Snap to bottom when user types
      setScrollOffset(0);
    },
    [activeId]
  );

  const scrollUp = useCallback(
    (amount = 3) => {
      if (!activeId) return;
      const session = sessionsRef.current.get(activeId);
      if (!session) return;
      const maxScroll = Math.max(0, getBufferLength(session.terminal) - session.terminal.rows);
      setScrollOffset((prev) => Math.min(maxScroll, prev + amount));
    },
    [activeId]
  );

  const scrollDown = useCallback(
    (amount = 3) => {
      setScrollOffset((prev) => Math.max(0, prev - amount));
    },
    []
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

  return {
    lines,
    activeId,
    scrollOffset,
    select,
    write,
    scrollUp,
    scrollDown,
    resize,
    connect,
    disconnect,
    disconnectAll,
  };
}
