import { Box, Text } from "ink";
import type { Agent } from "shared";
import { FolderGroup } from "./FolderGroup";
import { groupAgentsByFolder } from "../lib/path-utils";

export interface SidebarItem {
  type: "agent";
  agentId: string;
  cwd: string;
}

export function buildSidebarItems(agents: Agent[]): SidebarItem[] {
  const groups = groupAgentsByFolder(agents);
  const items: SidebarItem[] = [];
  for (const group of groups) {
    for (const agent of group.agents) {
      items.push({ type: "agent", agentId: agent.sessionId, cwd: group.cwd });
    }
  }
  return items;
}

interface Props {
  agents: Agent[];
  selectedIndex: number;
  focused: boolean;
  connected: boolean;
}

export function Sidebar({ agents, selectedIndex, focused, connected }: Props) {
  const items = buildSidebarItems(agents);
  const groups = groupAgentsByFolder(agents);

  return (
    <Box
      flexDirection="column"
      width={32}
      borderStyle="round"
      borderColor={focused ? "#3b82f6" : "#374151"}
      paddingX={1}
      overflowY="hidden"
    >
      <Box marginBottom={1}>
        <Text bold color="#e2e8f0">
          * AgentHub
        </Text>
        <Text> </Text>
        {connected
          ? <Text color="#22c55e">connected</Text>
          : <Text color="#ef4444">offline</Text>
        }
      </Box>
      {groups.map((group) => {
        const agentIds = group.agents.map((a) => a.sessionId);
        const selectedItem = items[selectedIndex];

        return (
          <FolderGroup
            key={group.cwd}
            cwd={group.cwd}
            agents={group.agents}
            selectedId={
              selectedItem?.type === "agent" && agentIds.includes(selectedItem.agentId)
                ? selectedItem.agentId
                : null
            }
          />
        );
      })}
      {agents.length === 0 && (
        <Box flexDirection="column" marginY={1} paddingX={2}>
          <Text color="#6b7280">No agents running</Text>
          <Text color="#4b5563">Press <Text color="#60a5fa" bold>n</Text> to spawn one</Text>
        </Box>
      )}
      <Box flexGrow={1} />
      <Text color="#374151">{"─".repeat(28)}</Text>
      <Box flexDirection="column" paddingTop={1}>
        <Text color="#6b7280">
          <Text color="#60a5fa" bold>n</Text> new  <Text color="#60a5fa" bold>k</Text> kill  <Text color="#60a5fa" bold>x</Text> close
        </Text>
        <Text color="#6b7280">
          <Text color="#60a5fa" bold>Tab</Text> pane  <Text color="#60a5fa" bold>q</Text> quit
        </Text>
      </Box>
    </Box>
  );
}
