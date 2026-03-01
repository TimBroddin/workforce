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
}

const MAX_SCROLLBACK_BYTES = 1024 * 1024; // ~1MB

export class PTYManager {
  private sessions = new Map<string, PTYSession>();

  spawn(opts: {
    cmd: string[];
    cwd: string;
    cols?: number;
    rows?: number;
    env?: Record<string, string>;
    onExit?: (id: string) => void;
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
    } as PTYSession;

    const proc = Bun.spawn({
      cmd: opts.cmd,
      cwd: opts.cwd,
      env: { ...process.env, ...opts.env, AGENTHUB_SESSION: id },
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
