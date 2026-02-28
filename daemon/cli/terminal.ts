import type { DaemonClient } from "./daemon-client";

export async function attachTerminal(
  client: DaemonClient,
  agentId: string
): Promise<void> {
  const cols = process.stdout.columns ?? 80;
  const rows = process.stdout.rows ?? 24;

  const wsUrl = client.terminalWsUrl(agentId, cols, rows);
  const ws = new WebSocket(wsUrl);

  return new Promise<void>((resolve, reject) => {
    let connected = false;

    ws.binaryType = "arraybuffer";

    ws.onopen = () => {
      connected = true;

      // Enter raw mode
      if (process.stdin.isTTY) {
        process.stdin.setRawMode(true);
      }
      process.stdin.resume();

      // Forward stdin to WebSocket as binary
      process.stdin.on("data", (data: Buffer) => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(data);
        }
      });

      // Handle terminal resize
      process.stdout.on("resize", () => {
        const newCols = process.stdout.columns;
        const newRows = process.stdout.rows;
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: "resize", cols: newCols, rows: newRows }));
        }
      });
    };

    ws.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        // Binary frame — PTY output
        process.stdout.write(Buffer.from(event.data));
      } else {
        // Text frame — control message (scrollback, etc.)
      }
    };

    ws.onclose = () => {
      cleanup();
      resolve();
    };

    ws.onerror = (err) => {
      cleanup();
      if (!connected) {
        reject(new Error("Failed to connect to agent terminal"));
      } else {
        resolve();
      }
    };

    function cleanup() {
      if (process.stdin.isTTY) {
        process.stdin.setRawMode(false);
      }
      process.stdin.pause();
      process.stdin.removeAllListeners("data");
      process.stdout.removeAllListeners("resize");
    }

    // Handle SIGINT — detach gracefully
    process.on("SIGINT", () => {
      ws.close();
    });
  });
}
