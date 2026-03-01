// packages/daemon/src/index.ts
import { mkdirSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { loadOrCreateToken, validateToken } from "./auth";
import { AgentStore } from "./agent-store";
import { PTYManager } from "./pty-manager";
import { WebSocketHub, type WsData, type TerminalWsData } from "./websocket-hub";
import {
  ALLOWED_AGENT_TYPES,
  ALLOWED_FLAGS,
  type SpawnRequest,
  type SocketMessage,
  type ClientControlMessage,
  type TerminalControlMessage,
} from "shared";

const AGENTHUB_DIR = join(homedir(), ".agenthub");
const TOKEN_PATH = join(AGENTHUB_DIR, "daemon.token");
const PORT_PATH = join(AGENTHUB_DIR, "daemon.port");
const PID_PATH = join(AGENTHUB_DIR, "daemon.pid");
const AGENTS_PATH = join(AGENTHUB_DIR, "agents.json");

// Ensure config dir exists
mkdirSync(AGENTHUB_DIR, { recursive: true });

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
          let ctrl: TerminalControlMessage;
          try {
            ctrl = JSON.parse(message) as TerminalControlMessage;
          } catch {
            console.warn("Invalid JSON in terminal WebSocket message");
            return;
          }
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
        let msg: ClientControlMessage;
        try {
          msg = JSON.parse(message as string) as ClientControlMessage;
        } catch {
          console.warn("Invalid JSON in control WebSocket message");
          return;
        }
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

console.log(`AgentHub daemon running on port ${server.port}`);

// Graceful shutdown
process.on("SIGTERM", async () => {
  console.log("Shutting down...");
  ptyManager.killAll();
  await store.persist();
  server.stop();
  try { unlinkSync(PID_PATH); } catch {}
  try { unlinkSync(PORT_PATH); } catch {}
  process.exit(0);
});

process.on("SIGINT", async () => {
  console.log("Shutting down...");
  ptyManager.killAll();
  await store.persist();
  server.stop();
  try { unlinkSync(PID_PATH); } catch {}
  try { unlinkSync(PORT_PATH); } catch {}
  process.exit(0);
});
