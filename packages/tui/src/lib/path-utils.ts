import { homedir } from "node:os";
import type { Agent } from "shared";

export function shortenPath(path: string): string {
  const home = homedir();
  if (path.startsWith(home)) {
    return "~" + path.slice(home.length);
  }
  return path;
}

export interface FolderGroup {
  cwd: string;
  agents: Agent[];
}

export function groupAgentsByFolder(agents: Agent[]): FolderGroup[] {
  const map = new Map<string, Agent[]>();
  for (const agent of agents) {
    const list = map.get(agent.cwd) ?? [];
    list.push(agent);
    map.set(agent.cwd, list);
  }
  return Array.from(map.entries()).map(([cwd, agents]) => ({ cwd, agents }));
}
