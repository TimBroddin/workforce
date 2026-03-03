import { test, expect } from "bun:test";
import { shortenPath, groupAgentsByFolder } from "../src/lib/path-utils";
import type { Agent } from "shared";

test("shortenPath replaces homedir with ~", () => {
  const home = process.env.HOME ?? "/Users/test";
  expect(shortenPath(`${home}/Projects/app`)).toBe("~/Projects/app");
});

test("shortenPath returns path unchanged if not under home", () => {
  expect(shortenPath("/tmp/something")).toBe("/tmp/something");
});

test("groupAgentsByFolder groups agents by cwd", () => {
  const agents = [
    { sessionId: "a", cwd: "/home/user/app" },
    { sessionId: "b", cwd: "/home/user/app" },
    { sessionId: "c", cwd: "/home/user/api" },
  ] as Agent[];

  const groups = groupAgentsByFolder(agents);
  expect(groups).toHaveLength(2);
  expect(groups[0].cwd).toBe("/home/user/app");
  expect(groups[0].agents).toHaveLength(2);
  expect(groups[1].cwd).toBe("/home/user/api");
  expect(groups[1].agents).toHaveLength(1);
});
