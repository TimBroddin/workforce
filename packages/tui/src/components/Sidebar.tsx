import React from "react";
import { Box, Text } from "ink";
import type { Agent } from "shared";
import { FolderGroup } from "./FolderGroup";
import { groupAgentsByFolder } from "../lib/path-utils";

interface SidebarItem {
  type: "agent" | "new";
  agentId?: string;
  cwd: string;
}

export function buildSidebarItems(agents: Agent[]): SidebarItem[] {
  const groups = groupAgentsByFolder(agents);
  const items: SidebarItem[] = [];
  for (const group of groups) {
    for (const agent of group.agents) {
      items.push({ type: "agent", agentId: agent.sessionId, cwd: group.cwd });
    }
    items.push({ type: "new", cwd: group.cwd });
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

  let itemIndex = 0;

  return (
    <Box
      flexDirection="column"
      width={24}
      borderStyle={focused ? "bold" : "single"}
      borderColor={focused ? "blue" : "gray"}
      paddingX={1}
    >
      <Text bold>
        AgentHub {connected ? <Text color="green">●</Text> : <Text color="red">●</Text>}
      </Text>
      <Text> </Text>
      {groups.map((group) => {
        const agentIds = group.agents.map((a) => a.sessionId);
        const selectedItem = items[selectedIndex];

        const result = (
          <FolderGroup
            key={group.cwd}
            cwd={group.cwd}
            agents={group.agents}
            selectedId={
              selectedItem?.type === "agent" && agentIds.includes(selectedItem.agentId!)
                ? selectedItem.agentId!
                : null
            }
            showNewButton={true}
            newSelected={
              selectedItem?.type === "new" && selectedItem.cwd === group.cwd
            }
          />
        );

        itemIndex += group.agents.length + 1; // agents + [+] New
        return result;
      })}
      {agents.length === 0 && (
        <Text dimColor>No agents running</Text>
      )}
    </Box>
  );
}
