import React from "react";
import { Text } from "ink";
import type { Agent, AgentStatus } from "shared";

const STATUS_ICONS: Record<AgentStatus, string> = {
  active: "●",
  idle: "○",
  waitingForInput: "◐",
  waitingForPermission: "◐",
  stopped: "✕",
  orphaned: "?",
};

const STATUS_COLORS: Record<AgentStatus, string> = {
  active: "green",
  idle: "gray",
  waitingForInput: "yellow",
  waitingForPermission: "yellow",
  stopped: "red",
  orphaned: "magenta",
};

interface Props {
  agent: Agent;
  selected: boolean;
}

export function AgentRow({ agent, selected }: Props) {
  const icon = STATUS_ICONS[agent.status] ?? "?";
  const color = STATUS_COLORS[agent.status] ?? "white";

  return (
    <Text
      backgroundColor={selected ? "blue" : undefined}
      color={selected ? "white" : undefined}
    >
      {"  "}
      <Text color={color}>{icon}</Text>
      {" "}
      {agent.name}
    </Text>
  );
}
