import { Box, Text } from "ink";
import type { Agent } from "shared";
import { AgentRow } from "./AgentRow";
import { shortenPath } from "../lib/path-utils";

interface Props {
  cwd: string;
  agents: Agent[];
  selectedId: string | null;
  showNewButton: boolean;
  newSelected: boolean;
}

export function FolderGroup({ cwd, agents, selectedId, showNewButton, newSelected }: Props) {
  return (
    <Box flexDirection="column">
      <Text bold dimColor>
        {shortenPath(cwd)}
      </Text>
      {agents.map((agent) => (
        <AgentRow
          key={agent.sessionId}
          agent={agent}
          selected={agent.sessionId === selectedId}
        />
      ))}
      {showNewButton && (
        <Text
          backgroundColor={newSelected ? "blue" : undefined}
          color={newSelected ? "white" : "gray"}
        >
          {"  [+] New"}
        </Text>
      )}
    </Box>
  );
}
