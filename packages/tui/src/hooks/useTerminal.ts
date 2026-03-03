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
