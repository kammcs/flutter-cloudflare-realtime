import { WebSocket } from "ws";
import { createDevServer, type DevServer, type DevServerOptions } from "../src/server.ts";

// Fake, test-only values. They are not real credentials.
export const APP_ID = "test-app-id";
export const APP_SECRET = "test-app-secret-not-real";
export const DEV_TOKEN = "test-dev-token-0123456789";
export const SFU = `https://rtc.live.cloudflare.com/v1/apps/${APP_ID}`;

export interface Upstream {
  url: string;
  method: string;
  headers: Headers;
  body: string | null;
}

export interface Running {
  server: DevServer;
  base: string;
  ws: string;
  upstream: Upstream[];
  logs: string[];
}

/** Starts a dev server on a free loopback port with a fake SFU. */
export async function start(overrides: Partial<DevServerOptions> = {}): Promise<Running> {
  const upstream: Upstream[] = [];
  const logs: string[] = [];
  let n = 0;
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    upstream.push({
      url,
      method: init?.method ?? "GET",
      headers: new Headers(init?.headers),
      body: typeof init?.body === "string" ? init.body : null,
    });
    if (url.startsWith(`${SFU}/sessions/new`)) {
      n++;
      return Response.json({ sessionId: `sess${n}` }, { status: 201 });
    }
    return Response.json({ ok: true });
  }) as typeof fetch;
  const server = createDevServer({
    appId: APP_ID,
    appSecret: APP_SECRET,
    devToken: DEV_TOKEN,
    fetch: fetchImpl,
    log: (m) => logs.push(m),
    ...overrides,
  });
  const address = await server.listen(0, "127.0.0.1");
  return {
    server,
    base: `http://127.0.0.1:${address.port}`,
    ws: `ws://127.0.0.1:${address.port}/signaling`,
    upstream,
    logs,
  };
}

/** A signaling test client that queues every message it receives. */
export class Client {
  readonly socket: WebSocket;
  readonly messages: Record<string, unknown>[] = [];
  #waiters: (() => void)[] = [];
  closeCode: number | null = null;
  readonly opened: Promise<void>;
  readonly closed: Promise<number>;

  constructor(url: string) {
    this.socket = new WebSocket(url);
    this.opened = new Promise((resolve, reject) => {
      this.socket.once("open", () => resolve());
      this.socket.once("error", reject);
    });
    this.closed = new Promise((resolve) => {
      this.socket.once("close", (code) => {
        this.closeCode = code;
        resolve(code);
        this.#notify();
      });
    });
    this.socket.on("message", (data) => {
      this.messages.push(JSON.parse(data.toString()) as Record<string, unknown>);
      this.#notify();
    });
  }

  static async open(url: string): Promise<Client> {
    const c = new Client(url);
    await c.opened;
    return c;
  }

  send(message: unknown): void {
    this.socket.send(typeof message === "string" ? message : JSON.stringify(message));
  }

  /** Waits for (and consumes) the next message matching `predicate`. */
  async next(predicate: (m: Record<string, unknown>) => boolean = () => true, timeoutMs = 2000) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const i = this.messages.findIndex(predicate);
      if (i >= 0) return this.messages.splice(i, 1)[0]!;
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error(`timed out; have ${JSON.stringify(this.messages)}`);
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, remaining);
        this.#waiters.push(() => {
          clearTimeout(t);
          resolve();
        });
      });
    }
  }

  /** The next `participants` message, as a list of participant IDs. */
  async nextIds(timeoutMs?: number): Promise<string[]> {
    const m = await this.next((m) => m.type === "participants", timeoutMs);
    return (m.participants as { participantId: string }[]).map((p) => p.participantId);
  }

  close(): void {
    this.socket.close();
  }

  #notify(): void {
    const w = this.#waiters;
    this.#waiters = [];
    for (const f of w) f();
  }
}

export function participant(id: string, extra: Record<string, unknown> = {}) {
  return { participantId: id, sessionId: null, tracks: {}, ...extra };
}
