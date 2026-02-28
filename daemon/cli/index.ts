#!/usr/bin/env bun
// daemon/cli/index.ts
import { ensureDaemon, DaemonClient } from "./daemon-client";
import { attachTerminal } from "./terminal";
import { ALLOWED_AGENT_TYPES } from "../shared/types";
import { homedir } from "node:os";
import { join } from "node:path";
import { existsSync } from "node:fs";

const args = process.argv.slice(2);
const command = args[0] ?? "claude";

async function main() {
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
    console.log("Usage: workforce daemon [start|stop|status]");
    return;
  }

  if (command === "install") {
    return installLaunchd();
  }

  if (command === "uninstall") {
    return uninstallLaunchd();
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
      console.log(`${a.sessionId.slice(0, 8)}  ${type}  ${status}  ${a.cwd}`);
    }
    return;
  }

  if (command === "attach") {
    const agentId = args[1];
    if (!agentId) {
      console.error("Usage: workforce attach <agent-id>");
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
      console.error("Usage: workforce kill <agent-id>");
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
  const agentType = ALLOWED_AGENT_TYPES.includes(command as any) ? command : "claude";
  const flags = args.filter((a) => a.startsWith("--"));
  const useTmux = flags.includes("--tmux");
  const useZellij = flags.includes("--zellij");
  const agentFlags = flags.filter((f) => f !== "--tmux" && f !== "--zellij");

  const cwd = process.cwd();
  const agentId = await client.spawnAgent({ agentType, cwd, flags: agentFlags });
  console.log(`Spawned ${agentType} agent: ${agentId.slice(0, 8)}`);

  if (useTmux) {
    const proc = Bun.spawn({
      cmd: ["tmux", "new-session", "-s", `workforce-${agentId.slice(0, 8)}`, "--", "workforce", "attach", agentId],
      stdio: ["inherit", "inherit", "inherit"],
    });
    await proc.exited;
  } else if (useZellij) {
    const proc = Bun.spawn({
      cmd: ["zellij", "run", "--", "workforce", "attach", agentId],
      stdio: ["inherit", "inherit", "inherit"],
    });
    await proc.exited;
  } else {
    await attachTerminal(client, agentId);
  }
}

async function handleHook(hookName: string, client: DaemonClient) {
  // Read JSON from stdin
  const stdin = await Bun.stdin.text();
  const event = JSON.parse(stdin);

  // Resolve session ID
  const sessionId =
    process.env.WORKFORCE_SESSION ?? event.session_id;

  const now = new Date().toISOString();

  const messageMap: Record<string, any> = {
    "session-start": {
      type: "updateStatus",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
      status: "active",
      transcript_path: event.transcript_path,
    },
    "session-end": {
      type: "deregister",
      session_id: sessionId,
      cwd: event.cwd,
      timestamp: now,
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
  const pidPath = join(homedir(), ".workforce", "daemon.pid");
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
  const pidPath = join(homedir(), ".workforce", "daemon.pid");
  const portPath = join(homedir(), ".workforce", "daemon.port");
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
  const plistPath = join(homedir(), "Library/LaunchAgents/com.workforce.daemon.plist");
  const bunPath = Bun.which("bun") ?? "/usr/local/bin/bun";
  const daemonScript = join(import.meta.dir, "../daemon/index.ts");

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.workforce.daemon</string>
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
    <string>${join(homedir(), ".workforce/daemon.stdout.log")}</string>
    <key>StandardErrorPath</key>
    <string>${join(homedir(), ".workforce/daemon.stderr.log")}</string>
</dict>
</plist>`;

  await Bun.write(plistPath, plist);
  const proc = Bun.spawn({ cmd: ["launchctl", "load", plistPath] });
  await proc.exited;
  console.log("Installed and started workforce daemon via launchd.");
}

async function uninstallLaunchd() {
  const plistPath = join(homedir(), "Library/LaunchAgents/com.workforce.daemon.plist");
  if (!existsSync(plistPath)) {
    console.log("Not installed.");
    return;
  }
  const proc = Bun.spawn({ cmd: ["launchctl", "unload", plistPath] });
  await proc.exited;
  const { unlinkSync } = await import("node:fs");
  unlinkSync(plistPath);
  console.log("Uninstalled workforce daemon from launchd.");
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
