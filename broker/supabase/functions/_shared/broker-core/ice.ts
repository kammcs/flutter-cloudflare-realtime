import type { TurnConfig } from "./types.ts";

/** One entry of `iceServers`, as in the browser's `RTCIceServer`. */
export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

/** Body of a `generate-ice-servers` response. */
export interface IceServersResponse {
  iceServers: IceServer[];
}

/** Cloudflare's public STUN server, returned when TURN isn't configured. */
export const STUN_ONLY: IceServersResponse = {
  iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }],
};

/** Thrown when Cloudflare's TURN API fails. The message is safe to log. */
export class TurnError extends Error {}

/**
 * Port 53 is blocked by browsers, and TURN URLs on it time out there
 * (Cloudflare's TURN docs). The other ports cover every client.
 */
function isPort53(url: string): boolean {
  return /^(?:stuns?|turns?):[^?]*:53(?:\?|$)/.test(url);
}

function normalize(body: unknown): IceServersResponse {
  if (typeof body !== "object" || body === null) {
    throw new TurnError("TURN response is not an object");
  }
  const raw = (body as { iceServers?: unknown }).iceServers;
  if (!Array.isArray(raw)) throw new TurnError("TURN response has no iceServers");
  const iceServers: IceServer[] = [];
  for (const entry of raw) {
    if (typeof entry !== "object" || entry === null) continue;
    const e = entry as { urls?: unknown; username?: unknown; credential?: unknown };
    const urlList = typeof e.urls === "string" ? [e.urls] : Array.isArray(e.urls) ? e.urls : [];
    const urls = urlList.filter((u): u is string => typeof u === "string" && !isPort53(u));
    if (urls.length === 0) continue;
    const server: IceServer = { urls };
    if (typeof e.username === "string") server.username = e.username;
    if (typeof e.credential === "string") server.credential = e.credential;
    iceServers.push(server);
  }
  if (iceServers.length === 0) throw new TurnError("TURN response has no usable servers");
  return { iceServers };
}

/**
 * Generates short-lived TURN credentials with Cloudflare's TURN API:
 * `POST {apiBaseUrl}/turn/keys/{keyId}/credentials/generate-ice-servers`
 * with `Authorization: Bearer <TURN key API token>` and `{"ttl": seconds}`.
 */
export async function generateIceServers(
  turn: TurnConfig,
  apiBaseUrl: string,
  fetchImpl: typeof fetch,
): Promise<IceServersResponse> {
  const url = `${apiBaseUrl}/turn/keys/${encodeURIComponent(turn.keyId)}/credentials/generate-ice-servers`;
  const response = await fetchImpl(url, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${turn.apiToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ ttl: turn.ttlSeconds ?? 86400 }),
  });
  if (!response.ok) {
    // Drain without reading the body into logs.
    await response.body?.cancel();
    throw new TurnError(`TURN API returned HTTP ${response.status}`);
  }
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new TurnError("TURN response is not JSON");
  }
  return normalize(body);
}
