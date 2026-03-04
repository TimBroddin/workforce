import { existsSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Agent, SpawnRequest } from "shared";

const AGENTHUB_DIR = join(homedir(), ".agenthub");
const TOKEN_PATH = join(AGENTHUB_DIR, "daemon.token");
const PORT_PATH = join(AGENTHUB_DIR, "daemon.port");
const PID_PATH = join(AGENTHUB_DIR, "daemon.pid");
const DAEMON_ENTRY = join(import.meta.dir, "daemon/index.ts");

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
      // PID stale, clean up before restarting
      try { unlinkSync(PID_PATH); } catch {}
      try { unlinkSync(PORT_PATH); } catch {}
    }
  }

  // Start daemon
  console.log("Starting agenthub daemon...");
  Bun.spawn({
    cmd: ["bun", "run", DAEMON_ENTRY],
    stdio: ["ignore", "ignore", "ignore"],
  });

  // Wait for port file to appear
  for (let i = 0; i < 50; i++) {
    await Bun.sleep(100);
    if (existsSync(PORT_PATH) && existsSync(TOKEN_PATH)) {
      try {
        const port = parseInt(await Bun.file(PORT_PATH).text());
        const token = (await Bun.file(TOKEN_PATH).text()).trim();
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
