import { Box, Text } from "ink";
import type { Agent, AgentStatus } from "shared";

const STATUS_ICONS: Record<AgentStatus, string> = {
  active: "●",
  idle: "○",
  waitingForInput: "◆",
  waitingForPermission: "◆",
  stopped: "×",
  orphaned: "!",
};

const STATUS_COLORS: Record<AgentStatus, string> = {
  active: "#22c55e",
  idle: "#6b7280",
  waitingForInput: "#f59e0b",
  waitingForPermission: "#f59e0b",
  stopped: "#ef4444",
  orphaned: "#a855f7",
};

const STATUS_LABELS: Record<AgentStatus, string> = {
  active: "",
  idle: "idle",
  waitingForInput: "input",
  waitingForPermission: "perm",
  stopped: "stopped",
  orphaned: "orphaned",
};

interface Props {
  agent: Agent;
  selected: boolean;
}

export function AgentRow({ agent, selected }: Props) {
  const icon = STATUS_ICONS[agent.status] ?? "?";
  const color = STATUS_COLORS[agent.status] ?? "white";
  const label = STATUS_LABELS[agent.status] ?? "";

  return (
    <Box>
      <Text
        backgroundColor={selected ? "#2563eb" : undefined}
        color={selected ? "white" : undefined}
      >
        {"  "}
        <Text color={selected ? "white" : color}>{icon}</Text>
        {" "}
        <Text bold={selected}>{agent.name}</Text>
        {label ? <Text color={selected ? "#93c5fd" : "#6b7280"}> {label}</Text> : ""}
      </Text>
    </Box>
  );
}
