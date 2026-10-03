/**
 * The dev server: the shared broker core mounted on a Node HTTP server, plus
 * the presence signaling WebSocket on `/signaling`. DEV ONLY.
 */

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import {
  type BrokerHandler,
  createBrokerHandler,
  formatBrokerError,
  InMemorySessionStore,
  type TurnConfig,
} from "../../../broker/supabase/functions/_shared/broker-core/mod.ts";
import { createDevAuthenticator, createUpgradeAuthorizer, DEV_USER_HEADER } from "./dev_auth.ts";
import { PresenceServer } from "./presence.ts";

/** Path of the signaling WebSocket. */
export const SIGNALING_PATH = "/signaling";
/** Unauthenticated liveness endpoint, handy to check a device can reach the laptop. */
export const HEALTH_PATH = "/healthz";

/** Bodies larger than this are refused before they reach the broker core. */
const MAX_BODY_BYTES = 2 * 1024 * 1024;

/** Options for {@link createDevServer}. */
export interface DevServerOptions {
  readonly appId: string;
  readonly appSecret: string;
  readonly turn?: TurnConfig;
  /** The shared dev bearer token. */
  readonly devToken: string;
  /** Allowed browser origins (Flutter Web), or `"*"`. Default `"*"`. */
  readonly corsOrigins?: "*" | readonly string[];
  /** Signaling heartbeat interval in milliseconds. Default 2000. */
  readonly heartbeatMs?: number;
  /** Upstream `fetch`, for tests. */
  readonly fetch?: typeof fetch;
  /** SFU API base URL override, for tests. */
  readonly apiBaseUrl?: string;
  /** Receives one-line, secret-free log messages. */
  readonly log?: (message: string) => void;
}

/** A running (or startable) dev server. */
export interface DevServer {
  readonly http: Server;
  readonly presence: PresenceServer;
  readonly broker: BrokerHandler;
  /** Starts listening. Resolves with the bound address. */
  listen(port: number, host: string): Promise<AddressInfo>;
  /** Stops the server and drops every connection. */
  close(): Promise<void>;
}

/** Creates the dev server. It doesn't listen until {@link DevServer.listen}. */
export function createDevServer(options: DevServerOptions): DevServer {
  const log = options.log ?? (() => {});
  const broker = createBrokerHandler({
    appId: options.appId,
    appSecret: options.appSecret,
    authenticate: createDevAuthenticator(options.devToken),
    // DEV ONLY: everyone who has the dev token may join every room.
    isRoomMember: () => true,
    sessionStore: new InMemorySessionStore(),
    cors: { allowedOrigins: options.corsOrigins ?? "*", extraAllowedHeaders: [DEV_USER_HEADER] },
    ...(options.turn ? { turn: options.turn } : {}),
    ...(options.fetch ? { fetch: options.fetch } : {}),
    ...(options.apiBaseUrl ? { apiBaseUrl: options.apiBaseUrl } : {}),
    // Route, a fixed message, and for upstream failures the error's code or
    // name and how long the call took: never URLs, headers, bodies or SDP.
    onError: (info) => log(`[broker] ${formatBrokerError(info)}`),
  });
  const presence = new PresenceServer({
    authorize: createUpgradeAuthorizer(options.devToken),
    log,
    ...(options.heartbeatMs ? { heartbeatMs: options.heartbeatMs } : {}),
  });

  const http = createServer((req, res) => {
    handleHttp(req, res, broker, log).catch(() => {
      if (!res.headersSent) res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ errorCode: "internal_error", errorDescription: "internal error" }));
    });
  });
  http.on("upgrade", (req, socket, head) => {
    if (pathOf(req) !== SIGNALING_PATH) {
      socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      return;
    }
    presence.handleUpgrade(req, socket, head);
  });

  return {
    http,
    presence,
    broker,
    listen: (port, host) =>
      new Promise((resolve, reject) => {
        http.once("error", reject);
        http.listen(port, host, () => {
          http.off("error", reject);
          resolve(http.address() as AddressInfo);
        });
      }),
    close: async () => {
      await presence.close();
      http.closeAllConnections();
      await new Promise<void>((resolve) => http.close(() => resolve()));
    },
  };
}

function pathOf(req: IncomingMessage): string {
  return new URL(req.url ?? "/", "http://localhost").pathname;
}

async function handleHttp(
  req: IncomingMessage,
  res: ServerResponse,
  broker: BrokerHandler,
  log: (message: string) => void,
): Promise<void> {
  if (pathOf(req) === HEALTH_PATH && (req.method === "GET" || req.method === "HEAD")) {
    res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    res.end(req.method === "HEAD" ? undefined : JSON.stringify({ ok: true, devOnly: true }));
    return;
  }
  const startedAt = performance.now();
  const request = await toWebRequest(req);
  if (request === null) {
    res.writeHead(413, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ errorCode: "payload_too_large", errorDescription: "request body too large" }));
    return;
  }
  const response = await broker(request);
  // Method, path, status and duration only: never headers, bodies, SDP or
  // tokens. The duration tells a slow upstream (a connect timeout is about
  // 10 s) from a quick failure; the line is written when the response is
  // ready, so the request arrived that long before its timestamp.
  const user = request.headers.get(DEV_USER_HEADER);
  const ms = Math.round(performance.now() - startedAt);
  log(`[broker] ${req.method} ${pathOf(req)} -> ${response.status} in ${ms} ms${user ? ` (${user})` : ""}`);
  await sendWebResponse(res, response);
}

/** Converts a Node request to a web `Request`, or `null` when the body is too large. */
export async function toWebRequest(req: IncomingMessage): Promise<Request | null> {
  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    if (value === undefined) continue;
    for (const v of Array.isArray(value) ? value : [value]) headers.append(name, v);
  }
  const method = req.method ?? "GET";
  let body: Uint8Array<ArrayBuffer> | undefined;
  if (method !== "GET" && method !== "HEAD") {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of req) {
      const buf = chunk as Buffer;
      size += buf.byteLength;
      if (size > MAX_BODY_BYTES) return null;
      chunks.push(buf);
    }
    body = new Uint8Array(Buffer.concat(chunks));
  }
  // The broker core only reads the path and query, so the host doesn't matter.
  const url = new URL(req.url ?? "/", "http://localhost");
  return new Request(url, { method, headers, ...(body !== undefined ? { body } : {}) });
}

/** Writes a web `Response` to a Node response. */
export async function sendWebResponse(res: ServerResponse, response: Response): Promise<void> {
  const headers: Record<string, string> = {};
  response.headers.forEach((value, name) => {
    headers[name] = value;
  });
  const body = response.body === null ? undefined : Buffer.from(await response.arrayBuffer());
  res.writeHead(response.status, headers);
  res.end(body);
}
