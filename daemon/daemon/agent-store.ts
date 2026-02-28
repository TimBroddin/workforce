import { existsSync } from "node:fs";
import type { Agent, SocketMessage } from "../shared/types";

export class AgentStore {
  private agents = new Map<string, Agent>();
  private persistPath: string;

  constructor(persistPath: string) {
    this.persistPath = persistPath;
  }

  addAgent(agent: Agent): void {
    this.agents.set(agent.sessionId, agent);
  }

  getAgent(sessionId: string): Agent | undefined {
    return this.agents.get(sessionId);
  }

  listAgents(): Agent[] {
    return [...this.agents.values()].sort(
      (a, b) => new Date(a.startedAt).getTime() - new Date(b.startedAt).getTime()
    );
  }

  removeAgent(sessionId: string): void {
    this.agents.delete(sessionId);
  }

  applyEvent(msg: SocketMessage): void {
    const agent = this.agents.get(msg.session_id);

    switch (msg.type) {
      case "register": {
        if (agent) {
          agent.status = msg.status ?? "active";
          agent.lastActivityAt = msg.timestamp;
        }
        break;
      }
      case "updateStatus": {
        if (agent) {
          agent.status = msg.status ?? agent.status;
          agent.lastActivityAt = msg.timestamp;
          if (msg.transcript_path) agent.transcriptPath = msg.transcript_path;
        }
        break;
      }
      case "updateTool": {
        if (agent) {
          agent.currentToolName = msg.tool_name ?? undefined;
          agent.status = msg.status ?? agent.status;
          agent.lastActivityAt = msg.timestamp;
        }
        break;
      }
      case "notification": {
        if (agent) {
          agent.status = msg.status ?? agent.status;
          agent.lastNotificationType = msg.notification_type;
          agent.notificationMessage = msg.notification_message;
          agent.lastActivityAt = msg.timestamp;
          if (msg.transcript_path) agent.transcriptPath = msg.transcript_path;
        }
        break;
      }
      case "subagentStart": {
        if (agent) {
          agent.subagentCount += 1;
          agent.status = msg.status ?? agent.status;
          agent.lastActivityAt = msg.timestamp;
        }
        break;
      }
      case "subagentStop": {
        if (agent) {
          agent.subagentCount = Math.max(0, agent.subagentCount - 1);
          agent.lastActivityAt = msg.timestamp;
        }
        break;
      }
      case "updateTokens": {
        if (agent) {
          agent.totalInputTokens += msg.input_tokens ?? 0;
          agent.totalOutputTokens += msg.output_tokens ?? 0;
          agent.totalCacheCreationTokens += msg.cache_creation_tokens ?? 0;
          agent.totalCacheReadTokens += msg.cache_read_tokens ?? 0;
          agent.lastActivityAt = msg.timestamp;
        }
        break;
      }
      case "deregister": {
        this.agents.delete(msg.session_id);
        break;
      }
    }
  }

  async persist(): Promise<void> {
    const data = JSON.stringify(this.listAgents(), null, 2);
    await Bun.write(this.persistPath, data);
  }

  async load(): Promise<void> {
    if (!existsSync(this.persistPath)) return;
    const file = Bun.file(this.persistPath);
    const text = await file.text();
    const agents: Agent[] = JSON.parse(text);
    for (const agent of agents) {
      this.agents.set(agent.sessionId, agent);
    }
  }
}
