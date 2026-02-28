// daemon/test/integration.test.ts
import { test, expect, beforeAll, afterAll, describe } from "bun:test";
import { join } from "node:path";
import { mkdirSync, rmSync, existsSync } from "node:fs";
import type { Agent } from "../shared/types";

const TEST_HOME = "/tmp/workforce-integration-test";
const WORKFORCE_DIR = join(TEST_HOME, ".workforce");
const TOKEN_PATH = join(WORKFORCE_DIR, "daemon.token");
const PORT_PATH = join(WORKFORCE_DIR, "daemon.port");
const DAEMON_ENTRY = join(import.meta.dir, "../daemon/index.ts");

let daemonProcess: ReturnType<typeof Bun.spawn>;
let baseUrl: string;
let token: string;

async function waitForFile(path: string, timeoutMs = 10000): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (existsSync(path)) {
      const content = await Bun.file(path).text();
      if (content.trim()) return content.trim();
    }
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for file: ${path}`);
}

describe("Daemon integration tests", () => {
  beforeAll(async () => {
    // Clean up any previous test state
    if (existsSync(TEST_HOME)) {
      rmSync(TEST_HOME, { recursive: true, force: true });
    }
    mkdirSync(WORKFORCE_DIR, { recursive: true });

    // Start the daemon with a test-specific HOME
    daemonProcess = Bun.spawn(["bun", "run", DAEMON_ENTRY], {
      env: {
        ...process.env,
        HOME: TEST_HOME,
      },
      stdout: "pipe",
      stderr: "pipe",
    });

    // Wait for the daemon to write its port and token files
    const [portStr, tokenStr] = await Promise.all([
      waitForFile(PORT_PATH),
      waitForFile(TOKEN_PATH),
    ]);

    baseUrl = `http://localhost:${portStr}`;
    token = tokenStr;
  });

  afterAll(async () => {
    // Kill the daemon process
    if (daemonProcess) {
      daemonProcess.kill("SIGTERM");
      // Wait briefly for graceful shutdown
      await Bun.sleep(500);
      try {
        daemonProcess.kill("SIGKILL");
      } catch {
        // Already dead
      }
    }

    // Clean up the test directory
    if (existsSync(TEST_HOME)) {
      rmSync(TEST_HOME, { recursive: true, force: true });
    }
  });

  function authHeaders(): HeadersInit {
    return {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    };
  }

  test("health endpoint returns ok", async () => {
    const res = await fetch(`${baseUrl}/api/health`, {
      headers: authHeaders(),
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.ok).toBe(true);
    expect(typeof body.agents).toBe("number");
  });

  test("list agents returns empty array initially", async () => {
    const res = await fetch(`${baseUrl}/api/agents`, {
      headers: authHeaders(),
    });
    expect(res.status).toBe(200);
    const agents: Agent[] = await res.json();
    expect(agents).toBeArrayOfSize(0);
  });

  test("unauthorized request is rejected with 401", async () => {
    const res = await fetch(`${baseUrl}/api/health`, {
      headers: { Authorization: "Bearer wrong-token" },
    });
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body.error).toBe("Unauthorized");
  });

  test("spawn agent via POST /api/agents", async () => {
    const res = await fetch(`${baseUrl}/api/agents`, {
      method: "POST",
      headers: authHeaders(),
      body: JSON.stringify({
        agentType: "bash",
        cwd: TEST_HOME,
      }),
    });
    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body.agentId).toBeDefined();
    expect(typeof body.agentId).toBe("string");
  });

  test("spawned agent appears in agent list", async () => {
    const res = await fetch(`${baseUrl}/api/agents`, {
      headers: authHeaders(),
    });
    expect(res.status).toBe(200);
    const agents: Agent[] = await res.json();
    expect(agents.length).toBeGreaterThanOrEqual(1);

    const agent = agents[0];
    expect(agent.agentType).toBe("bash");
    expect(agent.status).toBe("active");
    expect(agent.cwd).toBe(TEST_HOME);
    expect(agent.sessionId).toBeDefined();
  });

  test("POST hook event (updateTool) updates agent state", async () => {
    // First get the agent's sessionId
    const listRes = await fetch(`${baseUrl}/api/agents`, {
      headers: authHeaders(),
    });
    const agents: Agent[] = await listRes.json();
    expect(agents.length).toBeGreaterThanOrEqual(1);
    const sessionId = agents[0].sessionId;

    const now = new Date().toISOString();
    const eventRes = await fetch(`${baseUrl}/api/events`, {
      method: "POST",
      headers: authHeaders(),
      body: JSON.stringify({
        type: "updateTool",
        session_id: sessionId,
        cwd: TEST_HOME,
        timestamp: now,
        tool_name: "Read",
        status: "active",
      }),
    });
    expect(eventRes.status).toBe(200);
    const eventBody = await eventRes.json();
    expect(eventBody.ok).toBe(true);

    // Verify the agent state was updated
    const agentRes = await fetch(`${baseUrl}/api/agents/${sessionId}`, {
      headers: authHeaders(),
    });
    expect(agentRes.status).toBe(200);
    const updatedAgent: Agent = await agentRes.json();
    expect(updatedAgent.currentToolName).toBe("Read");
    expect(updatedAgent.lastActivityAt).toBe(now);
  });

  test("kill agent via DELETE /api/agents/:id", async () => {
    // Get the agent's sessionId
    const listRes = await fetch(`${baseUrl}/api/agents`, {
      headers: authHeaders(),
    });
    const agents: Agent[] = await listRes.json();
    expect(agents.length).toBeGreaterThanOrEqual(1);
    const sessionId = agents[0].sessionId;

    // Delete the agent
    const deleteRes = await fetch(`${baseUrl}/api/agents/${sessionId}`, {
      method: "DELETE",
      headers: authHeaders(),
    });
    expect(deleteRes.status).toBe(200);
    const deleteBody = await deleteRes.json();
    expect(deleteBody.ok).toBe(true);

    // Verify agent is gone
    const verifyRes = await fetch(`${baseUrl}/api/agents`, {
      headers: authHeaders(),
    });
    const remainingAgents: Agent[] = await verifyRes.json();
    const found = remainingAgents.find((a) => a.sessionId === sessionId);
    expect(found).toBeUndefined();
  });
});
