import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { installHooks, uninstallHooks, HOOK_EVENTS } from "../src/hooks";

const TEST_DIR = "/tmp/agenthub-test-hooks";
const TEST_SETTINGS = join(TEST_DIR, ".claude", "settings.json");

beforeEach(() => {
  mkdirSync(join(TEST_DIR, ".claude"), { recursive: true });
});

afterEach(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
});

test("HOOK_EVENTS contains all 9 events", () => {
  expect(HOOK_EVENTS).toHaveLength(9);
});

test("installHooks creates settings.json with all hooks", async () => {
  await installHooks("/usr/local/bin/agenthub", TEST_SETTINGS);
  const settings = JSON.parse(await Bun.file(TEST_SETTINGS).text());
  expect(settings.hooks).toBeDefined();
  expect(Object.keys(settings.hooks)).toHaveLength(9);
  expect(settings.hooks.SessionStart[0].hooks[0].command).toContain("agenthub session-start");
});

test("installHooks merges with existing settings", async () => {
  await Bun.write(TEST_SETTINGS, JSON.stringify({ env: { DEBUG: "1" } }));
  await installHooks("/usr/local/bin/agenthub", TEST_SETTINGS);
  const settings = JSON.parse(await Bun.file(TEST_SETTINGS).text());
  expect(settings.env.DEBUG).toBe("1");
  expect(settings.hooks).toBeDefined();
});

test("installHooks preserves existing non-agenthub hooks", async () => {
  const existing = {
    hooks: {
      SessionStart: [
        { matcher: "", hooks: [{ type: "command", command: "some-other-tool start" }] },
      ],
    },
  };
  await Bun.write(TEST_SETTINGS, JSON.stringify(existing));
  await installHooks("/usr/local/bin/agenthub", TEST_SETTINGS);
  const settings = JSON.parse(await Bun.file(TEST_SETTINGS).text());
  expect(settings.hooks.SessionStart.length).toBe(2);
});

test("uninstallHooks removes only agenthub hooks", async () => {
  const existing = {
    hooks: {
      SessionStart: [
        { matcher: "", hooks: [{ type: "command", command: "some-other-tool start" }] },
        { matcher: "", hooks: [{ type: "command", command: "/usr/local/bin/agenthub session-start" }] },
      ],
    },
  };
  await Bun.write(TEST_SETTINGS, JSON.stringify(existing));
  await uninstallHooks(TEST_SETTINGS);
  const settings = JSON.parse(await Bun.file(TEST_SETTINGS).text());
  expect(settings.hooks.SessionStart).toHaveLength(1);
  expect(settings.hooks.SessionStart[0].hooks[0].command).toContain("some-other-tool");
});

test("uninstallHooks handles no settings file", async () => {
  await uninstallHooks(join(TEST_DIR, "nonexistent", "settings.json"));
});
