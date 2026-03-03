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
