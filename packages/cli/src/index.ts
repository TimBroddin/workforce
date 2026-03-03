#!/usr/bin/env bun
// packages/cli/src/index.ts
import { ensureDaemon, DaemonClient } from "./daemon-client";
import { attachTerminal } from "./terminal";
import { installHooks, uninstallHooks, installOpenCodePlugin, uninstallOpenCodePlugin } from "./hooks";
import { ALLOWED_AGENT_TYPES } from "shared";
import { parseTranscriptTokens } from "shared/transcript";
import { homedir } from "node:os";
import { join } from "node:path";
import { existsSync } from "node:fs";

const args = process.argv.slice(2);

// Global flags handled before command dispatch
const GLOBAL_FLAGS = ["--version", "-V", "--help", "-h"];

// If first arg is a flag (starts with -) but not a global flag, treat as flag for default agent (claude)
const firstArg = args[0];
const firstArgIsAgentFlag = firstArg?.startsWith("-") && !GLOBAL_FLAGS.includes(firstArg);
const command = firstArgIsAgentFlag ? "claude" : (firstArg ?? "claude");

const pkg = await Bun.file(join(import.meta.dir, "../package.json")).json();

async function main() {
  if (command === "--version" || command === "-V") {
    console.log(pkg.version);
    return;
  }

  if (command === "help" || command === "--help" || command === "-h") {
    console.log(`agenthub — manage Claude Code agent sessions

Usage: agenthub [command] [options]
       agenthub [agent-flags]     Spawn claude with flags (e.g. --continue, --resume)

Commands:
  <agent-type>           Spawn an agent and attach (default: claude)
  list                   List running agents
  attach <id>            Attach to a running agent's terminal
  kill <id>              Kill a running agent
  daemon start|stop|status  Manage the background daemon
  install-hooks          Install hooks (--agent=claude|opencode, default: claude)
  uninstall-hooks        Remove hooks (--agent=claude|opencode, default: claude)
  install                Install daemon as a launchd service
  uninstall              Remove daemon launchd service
  tui                    Interactive terminal UI

Options:
  --tmux                 Open agent in a new tmux session
  --zellij               Open agent in a zellij pane

All other flags are passed through to the agent CLI.

Agent types: ${ALLOWED_AGENT_TYPES.join(", ")}`);
    return;
  }

  // Daemon management commands (don't need daemon running)
  if (command === "daemon") {
    const sub = args[1];
    if (sub === "start") {
      await ensureDaemon();
      return;
    }
    if (sub === "stop") {
      return daemonStop();
    }
    if (sub === "status") {
      return daemonStatus();
    }
    console.log("Usage: agenthub daemon [start|stop|status]");
    return;
  }

  if (command === "install") {
    return installLaunchd();
  }

  if (command === "uninstall") {
    return uninstallLaunchd();
  }

  if (command === "install-hooks") {
    const agentFlag = args.find((a) => a.startsWith("--agent="))?.split("=")[1];
    const agent = agentFlag ?? "claude";
    const binaryPath = Bun.which("agenthub") ?? "agenthub";
    if (agent === "claude") {
      const settingsPath = join(homedir(), ".claude", "settings.json");
      await installHooks(binaryPath, settingsPath);
      console.log("Claude Code hooks installed to ~/.claude/settings.json");
    } else if (agent === "opencode") {
      await installOpenCodePlugin(binaryPath);
      console.log("OpenCode plugin installed to ~/.config/opencode/plugins/agenthub.js");
    } else {
      console.error(`Unknown agent: ${agent}. Supported: claude, opencode`);
      process.exit(1);
    }
    return;
  }

  if (command === "uninstall-hooks") {
    const agentFlag = args.find((a) => a.startsWith("--agent="))?.split("=")[1];
    const agent = agentFlag ?? "claude";
    if (agent === "claude") {
      const settingsPath = join(homedir(), ".claude", "settings.json");
      await uninstallHooks(settingsPath);
      console.log("Claude Code hooks removed from ~/.claude/settings.json");
    } else if (agent === "opencode") {
      await uninstallOpenCodePlugin();
      console.log("OpenCode plugin removed");
    } else {
      console.error(`Unknown agent: ${agent}. Supported: claude, opencode`);
      process.exit(1);
    }
    return;
  }

  if (command === "tui") {
    const { port, token } = await ensureDaemon();
    const { startTui } = await import("@timbroddin/agenthub-tui");
    const waitUntilExit = startTui({ port, token });
    await waitUntilExit();
    return;
  }

  // Validate command before starting daemon
  const knownCommands = [
    "list", "attach", "kill", "tui",
    "session-start", "session-end",
    "pre-tool-use", "post-tool-use", "post-tool-use-failure",
    "notification", "stop",
    "subagent-start", "subagent-stop",
    ...ALLOWED_AGENT_TYPES,
  ];
  if (!knownCommands.includes(command)) {
    console.error(`Unknown command: ${command}\n`);
    console.log(`Run 'agenthub --help' for usage information.`);
    process.exit(1);
  }

  // Commands that need daemon
  const { port, token } = await ensureDaemon();
  const client = new DaemonClient(port, token);

  if (command === "list") {
    const agents = await client.listAgents();
    if (agents.length === 0) {
      console.log("No running agents.");
      return;
    }
    for (const a of agents) {
      const status = a.status.padEnd(20);
      const type = a.agentType.padEnd(10);
      const title = a.paneTitle ? `  ${a.paneTitle}` : "";
      console.log(`${a.sessionId.slice(0, 8)}  ${type}  ${status}  ${a.cwd}${title}`);
    }
    return;
  }

  if (command === "attach") {
    const agentId = args[1];
    if (!agentId) {
      console.error("Usage: agenthub attach <agent-id>");
      process.exit(1);
    }
    // Support short IDs
    const agents = await client.listAgents();
    const match = agents.find(
      (a) => a.sessionId === agentId || a.sessionId.startsWith(agentId)
    );
    if (!match) {
      console.error(`Agent not found: ${agentId}`);
      process.exit(1);
    }
    await attachTerminal(client, match.sessionId);
    return;
  }

  if (command === "kill") {
    const agentId = args[1];
    if (!agentId) {
      console.error("Usage: agenthub kill <agent-id>");
      process.exit(1);
    }
    const agents = await client.listAgents();
    const match = agents.find(
      (a) => a.sessionId === agentId || a.sessionId.startsWith(agentId)
    );
    if (!match) {
      console.error(`Agent not found: ${agentId}`);
      process.exit(1);
    }
    await client.killAgent(match.sessionId);
    console.log(`Killed agent ${match.sessionId.slice(0, 8)}`);
    return;
  }

  // Hook subcommands (called by Claude Code hooks)
  const hookCommands = [
    "session-start", "session-end",
    "pre-tool-use", "post-tool-use", "post-tool-use-failure",
    "notification", "stop",
    "subagent-start", "subagent-stop",
  ];

  if (hookCommands.includes(command)) {
    return handleHook(command, client);
  }

  // Default: spawn agent
  const agentType = command;
  const restArgs = firstArgIsAgentFlag ? args : args.slice(1);
  const useTmux = restArgs.includes("--tmux");
  const useZellij = restArgs.includes("--zellij");
  const agentFlags = restArgs.filter((f) => f !== "--tmux" && f !== "--zellij");

  const cwd = process.cwd();
  const agentId = await client.spawnAgent({ agentType, cwd, flags: agentFlags });
  console.log(`Spawned ${agentType} agent: ${agentId.slice(0, 8)}`);

  if (useTmux) {
    const proc = Bun.spawn({
      cmd: ["tmux", "new-session", "-s", `agenthub-${agentId.slice(0, 8)}`, "--", "agenthub", "attach", agentId],
      stdio: ["inherit", "inherit", "inherit"],
    });
    await proc.exited;
  } else if (useZellij) {
    const proc = Bun.spawn({
      cmd: ["zellij", "run", "--", "agenthub", "attach", agentId],
      stdio: ["inherit", "inherit", "inherit"],
    });
    await proc.exited;
  } else {
    await attachTerminal(client, agentId);
  }
}

async function handleHook(hookName: string, client: DaemonClient) {
  // Read JSON from stdin
  let event: any;
  try {
    const stdin = await Bun.stdin.text();
    event = JSON.parse(stdin);
  } catch {
    // Stdin read or parse failed — exit silently
    process.exit(0);
  }

  // Resolve session ID
  const sessionId =
    process.env.AGENTHUB_SESSION ?? event.session_id;

  const now = new Date().toISOString();

  // Special-case session-end: parse transcript tokens and mark stopped.
  // Don't deregister — the agent PTY may still be alive (e.g. /clear).
  // Actual deregistration happens when the PTY process exits.
  if (hookName === "session-end") {
    if (event.transcript_path) {
      const tokens = await parseTranscriptTokens(event.transcript_path);
      await client.postEvent({
        type: "updateTokens",
        session_id: sessionId,
        cwd: event.cwd,
        timestamp: now,
        input_tokens: tokens.inputTokens,
        output_tokens: tokens.outputTokens,
        cache_creation_tokens: tokens.cacheCreationTokens,
        cache_read_tokens: tokens.cacheReadTokens,
      });
    }
    await client.postEvent({
      type: "updateStatus",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "stopped",
    });
    return;
  }

  const messageMap: Record<string, any> = {
    "session-start": {
      type: "updateStatus",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      transcript_path: event.transcript_path,
    },
    "pre-tool-use": {
      type: "updateTool",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      tool_name: event.tool_name,
    },
    "post-tool-use": {
      type: "updateTool",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      tool_name: undefined,
    },
    "post-tool-use-failure": {
      type: "updateTool",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      tool_name: undefined,
    },
    notification: {
      type: "notification",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: event.type === "permission_prompt" ? "waitingForPermission" : "waitingForInput",
      notification_type: event.type,
      transcript_path: event.transcript_path,
      notification_message: event.message,
    },
    stop: {
      type: "updateStatus",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "stopped",
    },
    "subagent-start": {
      type: "subagentStart",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      agent_type: event.agent_type,
    },
    "subagent-stop": {
      type: "subagentStop",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      agent_type: event.agent_type,
    },
  };

  const msg = messageMap[hookName];
  if (msg) {
    await client.postEvent(msg);
  }
}

async function daemonStop() {
  const pidPath = join(homedir(), ".agenthub", "daemon.pid");
  if (!existsSync(pidPath)) {
    console.log("Daemon not running.");
    return;
  }
  const pid = parseInt(await Bun.file(pidPath).text());
  try {
    process.kill(pid, "SIGTERM");
    console.log("Daemon stopped.");
  } catch {
    console.log("Daemon not running (stale PID).");
  }
}

async function daemonStatus() {
  const pidPath = join(homedir(), ".agenthub", "daemon.pid");
  const portPath = join(homedir(), ".agenthub", "daemon.port");
  if (!existsSync(pidPath)) {
    console.log("Daemon: not running");
    return;
  }
  const pid = parseInt(await Bun.file(pidPath).text());
  try {
    process.kill(pid, 0);
    const port = await Bun.file(portPath).text();
    console.log(`Daemon: running (PID ${pid}, port ${port.trim()})`);
  } catch {
    console.log("Daemon: not running (stale PID)");
  }
}

async function installLaunchd() {
  const plistPath = join(homedir(), "Library/LaunchAgents/be.titansofindustry.agenthub.daemon.plist");
  const bunPath = Bun.which("bun") ?? "/usr/local/bin/bun";
  const daemonScript = join(import.meta.dir, "daemon/index.ts");

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>be.titansofindustry.agenthub.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>${bunPath}</string>
        <string>run</string>
        <string>${daemonScript}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${join(homedir(), ".agenthub/daemon.stdout.log")}</string>
    <key>StandardErrorPath</key>
    <string>${join(homedir(), ".agenthub/daemon.stderr.log")}</string>
</dict>
</plist>`;

  await Bun.write(plistPath, plist);
  const proc = Bun.spawn({ cmd: ["launchctl", "load", plistPath] });
  await proc.exited;
  console.log("Installed and started agenthub daemon via launchd.");
}

async function uninstallLaunchd() {
  const plistPath = join(homedir(), "Library/LaunchAgents/be.titansofindustry.agenthub.daemon.plist");
  if (!existsSync(plistPath)) {
    console.log("Not installed.");
    return;
  }
  const proc = Bun.spawn({ cmd: ["launchctl", "unload", plistPath] });
  await proc.exited;
  const { unlinkSync } = await import("node:fs");
  unlinkSync(plistPath);
  console.log("Uninstalled agenthub daemon from launchd.");
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
