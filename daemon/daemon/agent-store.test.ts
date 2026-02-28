import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { AgentStore } from "./agent-store";
import type { Agent, SocketMessage } from "../shared/types";

const TEST_DIR = "/tmp/workforce-test-store";
const TEST_AGENTS_PATH = `${TEST_DIR}/agents.json`;

beforeEach(() => {
  mkdirSync(TEST_DIR, { recursive: true });
});

afterEach(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
});

function makeAgent(overrides: Partial<Agent> = {}): Agent {
  return {
    sessionId: "test-123",
    name: "Test Agent",
    avatarSeed: "seed",
    cwd: "/tmp",
    agentType: "claude",
    status: "active",
    startedAt: new Date().toISOString(),
    lastActivityAt: new Date().toISOString(),
    subagentCount: 0,
    totalInputTokens: 0,
    totalOutputTokens: 0,
    totalCacheCreationTokens: 0,
    totalCacheReadTokens: 0,
    ...overrides,
  };
}

test("addAgent stores and retrieves agent", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  const agent = makeAgent();
  store.addAgent(agent);
  expect(store.getAgent("test-123")).toEqual(agent);
});

test("listAgents returns all agents", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent({ sessionId: "a" }));
  store.addAgent(makeAgent({ sessionId: "b" }));
  expect(store.listAgents()).toHaveLength(2);
});

test("removeAgent deletes agent", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  store.removeAgent("test-123");
  expect(store.getAgent("test-123")).toBeUndefined();
});

test("applyEvent updateStatus changes agent status", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  const msg: SocketMessage = {
    type: "updateStatus",
    session_id: "test-123",
    cwd: "/tmp",
    timestamp: new Date().toISOString(),
    status: "idle",
  };
  store.applyEvent(msg);
  expect(store.getAgent("test-123")?.status).toBe("idle");
});

test("applyEvent updateTool sets currentToolName", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  const msg: SocketMessage = {
    type: "updateTool",
    session_id: "test-123",
    cwd: "/tmp",
    timestamp: new Date().toISOString(),
    tool_name: "bash",
  };
  store.applyEvent(msg);
  expect(store.getAgent("test-123")?.currentToolName).toBe("bash");
});

test("applyEvent updateTokens accumulates tokens", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  const msg: SocketMessage = {
    type: "updateTokens",
    session_id: "test-123",
    cwd: "/tmp",
    timestamp: new Date().toISOString(),
    input_tokens: 100,
    output_tokens: 50,
  };
  store.applyEvent(msg);
  const agent = store.getAgent("test-123");
  expect(agent?.totalInputTokens).toBe(100);
  expect(agent?.totalOutputTokens).toBe(50);
});

test("applyEvent deregister removes agent", () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  const msg: SocketMessage = {
    type: "deregister",
    session_id: "test-123",
    cwd: "/tmp",
    timestamp: new Date().toISOString(),
  };
  store.applyEvent(msg);
  expect(store.getAgent("test-123")).toBeUndefined();
});

test("persist and load round-trips agents", async () => {
  const store = new AgentStore(TEST_AGENTS_PATH);
  store.addAgent(makeAgent());
  await store.persist();

  const store2 = new AgentStore(TEST_AGENTS_PATH);
  await store2.load();
  expect(store2.getAgent("test-123")).toBeDefined();
});
