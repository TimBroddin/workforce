import { existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

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

function isAgenthubHook(entry: any): boolean {
  return entry?.hooks?.some((h: any) =>
    typeof h.command === "string" && h.command.includes("agenthub")
  ) ?? false;
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
