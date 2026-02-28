import { test, expect } from "bun:test";
import { WebSocketHub } from "./websocket-hub";

test("WebSocketHub tracks control connections", () => {
  const hub = new WebSocketHub();
  const fakeWs = { send: () => {}, data: {} } as any;
  hub.addControlConnection(fakeWs);
  expect(hub.controlConnectionCount()).toBe(1);
  hub.removeControlConnection(fakeWs);
  expect(hub.controlConnectionCount()).toBe(0);
});

test("WebSocketHub tracks terminal connections by agent", () => {
  const hub = new WebSocketHub();
  const fakeWs = { send: () => {}, data: {} } as any;
  hub.addTerminalConnection("agent-1", fakeWs);
  expect(hub.terminalConnectionCount("agent-1")).toBe(1);
  hub.removeTerminalConnection("agent-1", fakeWs);
  expect(hub.terminalConnectionCount("agent-1")).toBe(0);
});

test("broadcastControl sends to all control connections", () => {
  const hub = new WebSocketHub();
  const sent: string[] = [];
  const fakeWs = { send: (msg: string) => sent.push(msg), data: {} } as any;
  hub.addControlConnection(fakeWs);
  hub.broadcastControl({ type: "agents", agents: [] });
  expect(sent).toHaveLength(1);
  expect(JSON.parse(sent[0]).type).toBe("agents");
});

test("broadcastTerminal sends binary to terminal connections", () => {
  const hub = new WebSocketHub();
  const sent: any[] = [];
  const fakeWs = { send: (msg: any) => sent.push(msg), data: {} } as any;
  hub.addTerminalConnection("agent-1", fakeWs);
  const data = new Uint8Array([72, 101, 108, 108, 111]);
  hub.broadcastTerminal("agent-1", data);
  expect(sent).toHaveLength(1);
});

test("getMinTerminalSize returns smallest dimensions", () => {
  const hub = new WebSocketHub();
  const ws1 = { send: () => {}, data: { cols: 120, rows: 40 } } as any;
  const ws2 = { send: () => {}, data: { cols: 80, rows: 24 } } as any;
  hub.addTerminalConnection("agent-1", ws1);
  hub.addTerminalConnection("agent-1", ws2);
  const size = hub.getMinTerminalSize("agent-1");
  expect(size).toEqual({ cols: 80, rows: 24 });
});
