// packages/shared/src/types.ts

export type AgentStatus =
  | "active"
  | "waitingForInput"
  | "waitingForPermission"
  | "idle"
  | "stopped"
  | "orphaned";

export interface Agent {
  sessionId: string;
  name: string;
  avatarSeed: string;
  cwd: string;
  agentType: string;
  model?: string;
  host?: string;
  status: AgentStatus;
  startedAt: string; // ISO8601
  lastActivityAt: string; // ISO8601
  currentToolName?: string;
  lastNotificationType?: string;
  subagentCount: number;
  paneTitle?: string;
  transcriptPath?: string;
  notificationMessage?: string;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalCacheCreationTokens: number;
  totalCacheReadTokens: number;
  pid?: number; // child process PID, set on spawn
}

export type SocketMessageType =
  | "register"
  | "updateStatus"
  | "updateTool"
  | "notification"
  | "subagentStart"
  | "subagentStop"
  | "deregister"
  | "updateTokens";

// Incoming from CLI hooks — uses snake_case JSON keys
export interface SocketMessage {
  type: SocketMessageType;
  session_id: string;
  cwd: string;
  timestamp: string; // ISO8601
  name?: string;
  avatar_seed?: string;
  model?: string;
  status?: AgentStatus;
  tool_name?: string;
  notification_type?: string;
  agent_type?: string;
  tmux_session?: string;
  input_tokens?: number;
  output_tokens?: number;
  cache_creation_tokens?: number;
  cache_read_tokens?: number;
  transcript_path?: string;
  notification_message?: string;
}

// Hook event base (stdin JSON from Claude Code hooks)
export interface HookEventBase {
  session_id: string;
  cwd: string;
  hook_event_name: string;
  transcript_path?: string;
}

export interface ToolUseEvent extends HookEventBase {
  tool_name: string;
  tool_input?: {
    command?: string;
    file_path?: string;
  };
}

export interface NotificationEvent extends HookEventBase {
  type?: string;
  message?: string;
}

export interface SubagentEvent extends HookEventBase {
  agent_type?: string;
}

// Spawn request
export interface SpawnRequest {
  agentType: string;
  cwd: string;
  flags?: string[];
}

// Control WebSocket messages (client → daemon)
export type ClientControlMessage =
  | { type: "snapshot" }
  | { type: "spawn"; agentType: string; cwd: string; flags?: string[] }
  | { type: "kill"; agentId: string };

// Control WebSocket messages (daemon → client)
export type DaemonControlMessage =
  | { type: "agents"; agents: Agent[] }
  | { type: "event"; event: SocketMessage }
  | { type: "spawned"; agentId: string }
  | { type: "error"; message: string };

// Terminal WebSocket messages (text frames only — binary frames are raw PTY data)
export type TerminalControlMessage = { type: "resize"; cols: number; rows: number };

export type TerminalServerMessage = { type: "scrollback"; data: string }; // base64

// Allowed agent types and flags
export const ALLOWED_AGENT_TYPES = ["claude", "codex", "opencode", "bash"] as const;
export const ALLOWED_FLAGS = ["--dangerously-skip-permissions"] as const;
