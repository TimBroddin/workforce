import { test, expect, afterEach } from "bun:test";
import { PTYManager } from "../src/pty-manager";

const manager = new PTYManager();

afterEach(() => {
  manager.killAll();
});

test("spawn creates a session and returns an id", () => {
  const id = manager.spawn({ cmd: ["echo", "hello"], cwd: "/tmp" });
  expect(id).toMatch(/^[a-f0-9-]{36}$/);
  expect(manager.getSession(id)).toBeDefined();
});

test("listSessions returns all sessions", () => {
  manager.spawn({ cmd: ["sleep", "10"], cwd: "/tmp" });
  manager.spawn({ cmd: ["sleep", "10"], cwd: "/tmp" });
  expect(manager.listSessions()).toHaveLength(2);
});

test("kill terminates session", async () => {
  const id = manager.spawn({ cmd: ["sleep", "60"], cwd: "/tmp" });
  manager.kill(id);
  // Give process time to exit
  await Bun.sleep(200);
  expect(manager.getSession(id)).toBeUndefined();
});

test("resize updates session dimensions", () => {
  const id = manager.spawn({ cmd: ["sleep", "10"], cwd: "/tmp" });
  manager.resize(id, 120, 40);
  const session = manager.getSession(id);
  expect(session?.cols).toBe(120);
  expect(session?.rows).toBe(40);
});

test("scrollback captures output", async () => {
  const id = manager.spawn({ cmd: ["echo", "hello world"], cwd: "/tmp" });
  // Wait for output
  await Bun.sleep(300);
  const scrollback = manager.getScrollback(id);
  expect(scrollback.length).toBeGreaterThan(0);
});

test("subscribe and unsubscribe work", () => {
  const id = manager.spawn({ cmd: ["sleep", "10"], cwd: "/tmp" });
  const received: Uint8Array[] = [];
  const sub = (data: Uint8Array) => { received.push(data); };
  manager.subscribe(id, sub);
  manager.unsubscribe(id, sub);
  const session = manager.getSession(id);
  expect(session?.subscribers.size).toBe(0);
});
