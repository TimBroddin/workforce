import type { ServerWebSocket } from "bun";
import type { DaemonControlMessage } from "shared";

export interface TerminalWsData {
  type: "terminal";
  agentId: string;
  cols: number;
  rows: number;
}

export interface ControlWsData {
  type: "control";
}

export type WsData = TerminalWsData | ControlWsData;

export class WebSocketHub {
  private controlConnections = new Set<ServerWebSocket<WsData> | any>();
  private terminalConnections = new Map<
    string,
    Set<ServerWebSocket<WsData> | any>
  >();

  addControlConnection(ws: any): void {
    this.controlConnections.add(ws);
  }

  removeControlConnection(ws: any): void {
    this.controlConnections.delete(ws);
  }

  controlConnectionCount(): number {
    return this.controlConnections.size;
  }

  addTerminalConnection(agentId: string, ws: any): void {
    if (!this.terminalConnections.has(agentId)) {
      this.terminalConnections.set(agentId, new Set());
    }
    this.terminalConnections.get(agentId)!.add(ws);
  }

  removeTerminalConnection(agentId: string, ws: any): void {
    this.terminalConnections.get(agentId)?.delete(ws);
    if (this.terminalConnections.get(agentId)?.size === 0) {
      this.terminalConnections.delete(agentId);
    }
  }

  terminalConnectionCount(agentId: string): number {
    return this.terminalConnections.get(agentId)?.size ?? 0;
  }

  broadcastControl(message: DaemonControlMessage): void {
    const json = JSON.stringify(message);
    for (const ws of this.controlConnections) {
      ws.send(json);
    }
  }

  broadcastTerminal(agentId: string, data: Uint8Array): void {
    const connections = this.terminalConnections.get(agentId);
    if (!connections) return;
    for (const ws of connections) {
      ws.send(data);
    }
  }

  getMinTerminalSize(
    agentId: string
  ): { cols: number; rows: number } | null {
    const connections = this.terminalConnections.get(agentId);
    if (!connections || connections.size === 0) return null;

    let minCols = Infinity;
    let minRows = Infinity;
    for (const ws of connections) {
      const data = ws.data;
      if (data.cols && data.cols < minCols) minCols = data.cols;
      if (data.rows && data.rows < minRows) minRows = data.rows;
    }
    return { cols: minCols, rows: minRows };
  }

  getTerminalAgentIds(): string[] {
    return [...this.terminalConnections.keys()];
  }
}
