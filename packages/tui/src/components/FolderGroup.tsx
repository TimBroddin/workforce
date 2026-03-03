import { Box, Text } from "ink";
import type { Agent } from "shared";
import { AgentRow } from "./AgentRow";
import { shortenPath } from "../lib/path-utils";

interface Props {
  cwd: string;
  agents: Agent[];
  selectedId: string | null;
}

export function FolderGroup({ cwd, agents, selectedId }: Props) {
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
    </Box>
  );
}
