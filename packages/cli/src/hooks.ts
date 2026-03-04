import { existsSync, mkdirSync, unlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

export const HOOK_EVENTS = [
  { claudeEvent: "SessionStart", subcommand: "session-start" },
  { claudeEvent: "PreToolUse", subcommand: "pre-tool-use" },
  { claudeEvent: "PostToolUse", subcommand: "post-tool-use" },
  { claudeEvent: "PostToolUseFailure", subcommand: "post-tool-use-failure" },
  { claudeEvent: "Notification", subcommand: "notification" },
  { claudeEvent: "SubagentStart", subcommand: "subagent-start" },
  { claudeEvent: "SubagentStop", subcommand: "subagent-stop" },
  { claudeEvent: "Stop", subcommand: "stop" },
  { claudeEvent: "SessionEnd", subcommand: "session-end" },
] as const;

function makeHookEntry(binaryPath: string, subcommand: string) {
  return {
    matcher: "",
    hooks: [{ type: "command", command: `${binaryPath} ${subcommand}` }],
  };
}

const HOOK_SUBCOMMANDS = HOOK_EVENTS.map((e) => e.subcommand);

function isAgenthubHook(entry: any): boolean {
  return entry?.hooks?.some((h: any) => {
    if (typeof h.command !== "string") return false;
    const cmd = h.command;
    if (cmd.includes("agenthub")) return true;
    // Match stale entries like "bun session-start" or "/path/to/bun stop"
    const parts = cmd.trim().split(/\s+/);
    const binary = parts[0]?.split("/").pop();
    const subcommand = parts[1];
    if (binary === "bun" && subcommand && HOOK_SUBCOMMANDS.includes(subcommand)) return true;
    return false;
  }) ?? false;
}

export async function installHooks(binaryPath: string, settingsPath: string): Promise<void> {
  let settings: any = {};

  if (existsSync(settingsPath)) {
    const text = await Bun.file(settingsPath).text();
    settings = JSON.parse(text);
  }

  if (!settings.hooks) {
    settings.hooks = {};
  }

  for (const { claudeEvent, subcommand } of HOOK_EVENTS) {
    if (!settings.hooks[claudeEvent]) {
      settings.hooks[claudeEvent] = [];
    }

    // Remove existing agenthub entries for this event
    settings.hooks[claudeEvent] = settings.hooks[claudeEvent].filter(
      (entry: any) => !isAgenthubHook(entry)
    );

    // Add new entry
    settings.hooks[claudeEvent].push(makeHookEntry(binaryPath, subcommand));
  }

  mkdirSync(dirname(settingsPath), { recursive: true });
  await Bun.write(settingsPath, JSON.stringify(settings, null, 2));
}

export async function uninstallHooks(settingsPath: string): Promise<void> {
  if (!existsSync(settingsPath)) return;

  const text = await Bun.file(settingsPath).text();
  const settings = JSON.parse(text);

  if (!settings.hooks) return;

  for (const key of Object.keys(settings.hooks)) {
    settings.hooks[key] = settings.hooks[key].filter(
      (entry: any) => !isAgenthubHook(entry)
    );
    if (settings.hooks[key].length === 0) {
      delete settings.hooks[key];
    }
  }

  if (Object.keys(settings.hooks).length === 0) {
    delete settings.hooks;
  }

  await Bun.write(settingsPath, JSON.stringify(settings, null, 2));
}

// OpenCode plugin

const OPENCODE_PLUGIN_PATH = join(homedir(), ".config", "opencode", "plugins", "agenthub.js");

function renderOpenCodePlugin(binaryPath: string): string {
  return `// agenthub-opencode-plugin
import { existsSync } from "node:fs";
import { spawn } from "node:child_process";

const AGENTHUB_BINARY = ${JSON.stringify(binaryPath)};

export default async function AgenthubPlugin(ctx) {
  const defaultCwd = ctx.worktree || ctx.directory || process.cwd();
  const sessionDirectories = new Map();

  function getSessionID(event) {
    return (
      event?.properties?.sessionID ??
      event?.properties?.info?.id ??
      event?.properties?.request?.sessionID ??
      event?.properties?.session?.id ??
      "opencode"
    );
  }

  function resolveCwd(sessionID, fallback) {
    return sessionDirectories.get(sessionID) || fallback || defaultCwd;
  }

  function send(subcommand, payload) {
    const command = existsSync(AGENTHUB_BINARY) ? AGENTHUB_BINARY : "agenthub";
    try {
      const child = spawn(command, [subcommand], {
        stdio: ["pipe", "ignore", "ignore"],
        env: process.env,
      });
      child.on("error", () => {});
      child.stdin.end(JSON.stringify(payload));
    } catch {}
  }

  function basePayload(sessionID, cwd, hookEventName) {
    return { session_id: sessionID, cwd, hook_event_name: hookEventName };
  }

  return {
    async event({ event }) {
      const type = event?.type;
      if (!type) return;

      if (type === "session.created" || type === "session.updated") {
        const sessionID = getSessionID(event);
        const cwd = event?.properties?.info?.directory || resolveCwd(sessionID);
        sessionDirectories.set(sessionID, cwd);
        send("session-start", basePayload(sessionID, cwd, "SessionStart"));
        return;
      }

      if (type === "session.deleted") {
        const sessionID = getSessionID(event);
        const cwd = resolveCwd(sessionID);
        send("session-end", basePayload(sessionID, cwd, "SessionEnd"));
        sessionDirectories.delete(sessionID);
        return;
      }

      if (type === "session.idle") {
        const sessionID = getSessionID(event);
        const cwd = resolveCwd(sessionID);
        send("stop", basePayload(sessionID, cwd, "Stop"));
        return;
      }

      if (type === "session.status") {
        const sessionID = getSessionID(event);
        const cwd = resolveCwd(sessionID);
        const status = event?.properties?.status?.type;
        if (status === "idle") {
          send("stop", basePayload(sessionID, cwd, "Stop"));
        } else {
          send("session-start", basePayload(sessionID, cwd, "SessionStart"));
        }
        return;
      }

      if (type === "permission.asked" || type === "permission.updated") {
        const sessionID = getSessionID(event);
        const cwd = resolveCwd(sessionID);
        send("notification", {
          ...basePayload(sessionID, cwd, "Notification"),
          type: "permission_prompt",
        });
        return;
      }

      if (type === "question.asked") {
        const sessionID = getSessionID(event);
        const cwd = resolveCwd(sessionID);
        send("notification", {
          ...basePayload(sessionID, cwd, "Notification"),
          type: "input_prompt",
        });
      }
    },

    async "tool.execute.before"(input) {
      const sessionID = input?.sessionID || "opencode";
      const cwd = resolveCwd(sessionID);
      send("pre-tool-use", {
        ...basePayload(sessionID, cwd, "PreToolUse"),
        tool_name: input?.tool || "tool",
      });
    },

    async "tool.execute.after"(input) {
      const sessionID = input?.sessionID || "opencode";
      const cwd = resolveCwd(sessionID);
      send("post-tool-use", {
        ...basePayload(sessionID, cwd, "PostToolUse"),
        tool_name: input?.tool || "tool",
      });
    },
  };
}
`;
}

export async function installOpenCodePlugin(binaryPath: string): Promise<void> {
  mkdirSync(dirname(OPENCODE_PLUGIN_PATH), { recursive: true });
  await Bun.write(OPENCODE_PLUGIN_PATH, renderOpenCodePlugin(binaryPath));
}

export async function uninstallOpenCodePlugin(): Promise<void> {
  if (!existsSync(OPENCODE_PLUGIN_PATH)) return;
  unlinkSync(OPENCODE_PLUGIN_PATH);
}
