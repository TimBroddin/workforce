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
    <Box flexDirection="column" marginBottom={1}>
      <Text color="#8b5cf6" bold>
        {"  "}📁 {shortenPath(cwd)}
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
