import type { DaemonClient } from "./daemon-client";
import { appendFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const DEBUG_LOG = join(homedir(), ".agenthub", "terminal-debug.log");

function debugLog(msg: string) {
  try {
    appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${msg}\n`);
  } catch {}
}

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

      debugLog(`isTTY=${process.stdin.isTTY} cols=${cols} rows=${rows}`);

      // Enter raw mode
      if (process.stdin.isTTY) {
        process.stdin.setRawMode(true);
      }
      process.stdin.resume();

      // Forward stdin to WebSocket as binary
      // Ctrl+D detaches from the terminal without killing the agent
      const KITTY_CTRL_D = Buffer.from([27, 91, 49, 48, 48, 59, 53, 117]); // ESC[100;5u
      const onData = (data: Buffer) => {
        const bytes = Array.from(data instanceof Uint8Array ? data : Buffer.from(data)).slice(0, 10);
        debugLog(`onData: type=${typeof data} isBuffer=${Buffer.isBuffer(data)} len=${data.length} bytes=${JSON.stringify(bytes)}`);

        const isCtrlD =
          (data.length === 1 && data[0] === 0x04) ||
          (data.length === KITTY_CTRL_D.length && data.equals(KITTY_CTRL_D));

        if (isCtrlD) {
          // Ctrl+D — detach
          debugLog("ctrl+d detected — detaching");
          process.stdout.write("\r\n[detached]\r\n");
          ws.close();
          return;
        }

        if (ws.readyState === WebSocket.OPEN) {
          ws.send(data);
        }
      };
      process.stdin.on("data", onData);

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
      process.exit(0);
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
    process.once("SIGINT", () => {
      ws.close();
    });
  });
}
