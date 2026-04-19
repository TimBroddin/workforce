export type OutputSubscriber = (data: Uint8Array) => void;

export interface PTYSession {
  id: string;
  process: ReturnType<typeof Bun.spawn>;
  cols: number;
  rows: number;
  scrollback: Uint8Array[];
  scrollbackSize: number;
  subscribers: Set<OutputSubscriber>;
  exited: boolean;
  onExit?: (id: string) => void;
  onTitle?: (id: string, title: string) => void;
  /** Buffer for incomplete OSC sequences spanning multiple data chunks */
  oscBuffer: string;
}

const MAX_SCROLLBACK_BYTES = 1024 * 1024; // ~1MB

// OSC 0 (icon name + title) and OSC 2 (title) set the terminal title.
// Format: \x1b]0;title\x07  or  \x1b]2;title\x07  (BEL terminator)
//         \x1b]0;title\x1b\\    or \x1b]2;title\x1b\\  (ST terminator)
const OSC_TITLE_RE = /\x1b\]([02]);([^\x07\x1b]*?)(?:\x07|\x1b\\)/g;
// Detect an incomplete OSC at the end of a chunk (started but no terminator)
const OSC_INCOMPLETE_RE = /\x1b\]([02]);[^\x07\x1b]*$/;

export class PTYManager {
  private sessions = new Map<string, PTYSession>();

  spawn(opts: {
    cmd: string[];
    cwd: string;
    cols?: number;
    rows?: number;
    env?: Record<string, string>;
    onExit?: (id: string) => void;
    onTitle?: (id: string, title: string) => void;
  }): string {
    const id = crypto.randomUUID();
    const cols = opts.cols ?? 80;
    const rows = opts.rows ?? 24;

    const session: PTYSession = {
      id,
      cols,
      rows,
      scrollback: [],
      scrollbackSize: 0,
      subscribers: new Set(),
      exited: false,
      onExit: opts.onExit,
      onTitle: opts.onTitle,
      oscBuffer: "",
    } as PTYSession;

    const proc = Bun.spawn({
      cmd: opts.cmd,
      cwd: opts.cwd,
      env: {
        ...process.env,
        ...opts.env,
        AGENTHUB_SESSION: id,
        CLAUDECODE: "",
        TERM: "xterm-256color",
        COLORTERM: "truecolor",
        // Override TERM_PROGRAM so programs don't attempt inline image protocols
        // (iTerm2/Kitty) that xterm-headless can't handle.
        TERM_PROGRAM: "xterm",
      },
      terminal: {
        cols,
        rows,
        data: (_terminal: any, data: Uint8Array) => {
          // Store in scrollback
          session.scrollback.push(data);
          session.scrollbackSize += data.byteLength;

          // Trim scrollback if too large
          while (session.scrollbackSize > MAX_SCROLLBACK_BYTES && session.scrollback.length > 1) {
            const removed = session.scrollback.shift()!;
            session.scrollbackSize -= removed.byteLength;
          }

          // Extract terminal title from OSC escape sequences
          if (session.onTitle) {
            const text = session.oscBuffer + new TextDecoder().decode(data);
            OSC_TITLE_RE.lastIndex = 0;
            let match: RegExpExecArray | null;
            let lastTitle: string | undefined;
            while ((match = OSC_TITLE_RE.exec(text)) !== null) {
              lastTitle = match[2];
            }
            // Buffer any incomplete OSC sequence at the end for next chunk
            const incomplete = OSC_INCOMPLETE_RE.exec(text);
            session.oscBuffer = incomplete ? incomplete[0] : "";
            if (lastTitle !== undefined) {
              session.onTitle(id, lastTitle);
            }
          }

          // Broadcast to subscribers
          for (const sub of session.subscribers) {
            sub(data);
          }
        },
        exit: () => {
          session.exited = true;
          session.onExit?.(id);
        },
      },
    });

    session.process = proc;
    this.sessions.set(id, session);
    return id;
  }

  getSession(id: string): PTYSession | undefined {
    return this.sessions.get(id);
  }

  listSessions(): PTYSession[] {
    return [...this.sessions.values()];
  }

  kill(id: string): void {
    const session = this.sessions.get(id);
    if (!session) return;
    this.sessions.delete(id);
    if (!session.exited) {
      session.process.kill("SIGHUP");
      // Fallback kill after 2 seconds
      setTimeout(() => {
        try {
          session.process.kill("SIGKILL");
        } catch {
          // Process may already be dead
        }
      }, 2000);
    }
  }

  killAll(): void {
    for (const [, session] of [...this.sessions.entries()]) {
      if (!session.exited) {
        try {
          session.process.kill("SIGKILL");
        } catch {
          // Process may already be dead
        }
      }
    }
    this.sessions.clear();
  }

  resize(id: string, cols: number, rows: number): void {
    const session = this.sessions.get(id);
    if (!session) return;
    session.cols = cols;
    session.rows = rows;
    session.process.terminal?.resize(cols, rows);
  }

  write(id: string, data: string | BufferSource): void {
    const session = this.sessions.get(id);
    if (!session) return;
    session.process.terminal?.write(data as any);
  }

  getScrollback(id: string): Uint8Array[] {
    return this.sessions.get(id)?.scrollback ?? [];
  }

  subscribe(id: string, subscriber: OutputSubscriber): void {
    this.sessions.get(id)?.subscribers.add(subscriber);
  }

  unsubscribe(id: string, subscriber: OutputSubscriber): void {
    this.sessions.get(id)?.subscribers.delete(subscriber);
  }
}
