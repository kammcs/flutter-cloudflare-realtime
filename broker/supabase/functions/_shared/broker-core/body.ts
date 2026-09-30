/**
 * Request body inspection for rule 4 (same-room pulls).
 *
 * The broker parses every JSON body, collects each `sessionId` it names (at any
 * depth: `tracks[]`, `dataChannels[]`, `dataChannel`, and anything the SFU API
 * adds later), and forwards its own re-serialization of the parsed value. So
 * what Cloudflare receives is exactly what was checked; duplicate keys and
 * other parser differentials can't smuggle a different `sessionId` through.
 */

/** Keys the broker reasons about, which must use their exact spelling. */
const CANONICAL_KEYS = ["sessionId", "tracks", "dataChannels", "dataChannel", "location"];
const CANONICAL_BY_LOWER = new Map(CANONICAL_KEYS.map((k) => [k.toLowerCase(), k]));

const MAX_DEPTH = 32;

/** Thrown for a body the broker refuses to forward. The message is safe to return. */
export class BadBodyError extends Error {}

/** A parsed, inspected request body. */
export interface InspectedBody {
  /** The JSON to forward, or `null` when the request had no body. */
  readonly json: string | null;
  /** Every `sessionId` value found in the body. */
  readonly sessionIds: ReadonlySet<string>;
  /** Entries in `tracks` / `dataChannels` with `location: "remote"` and no `sessionId`. */
  readonly remoteEntriesWithoutSessionId: number;
}

/** The result for a request without a body. */
export const EMPTY_BODY: InspectedBody = {
  json: null,
  sessionIds: new Set(),
  remoteEntriesWithoutSessionId: 0,
};

function walk(value: unknown, depth: number, found: Set<string>): void {
  if (depth > MAX_DEPTH) throw new BadBodyError("body is nested too deeply");
  if (Array.isArray(value)) {
    for (const item of value) walk(item, depth + 1, found);
    return;
  }
  if (typeof value !== "object" || value === null) return;
  for (const [key, child] of Object.entries(value)) {
    const canonical = CANONICAL_BY_LOWER.get(key.toLowerCase());
    if (canonical !== undefined && canonical !== key) {
      // Some JSON decoders match keys case-insensitively. Refuse look-alikes.
      throw new BadBodyError(`unexpected key spelling: ${key.slice(0, 32)}`);
    }
    if (key === "sessionId") {
      if (typeof child !== "string") throw new BadBodyError("sessionId must be a string");
      found.add(child);
      continue;
    }
    walk(child, depth + 1, found);
  }
}

function countRemoteWithoutSessionId(body: Record<string, unknown>): number {
  let count = 0;
  for (const key of ["tracks", "dataChannels"]) {
    const list = body[key];
    if (list === undefined) continue;
    if (!Array.isArray(list)) throw new BadBodyError(`${key} must be an array`);
    for (const entry of list) {
      if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
        throw new BadBodyError(`${key} entries must be objects`);
      }
      const e = entry as Record<string, unknown>;
      if (e["location"] === "remote" && e["sessionId"] === undefined) count++;
    }
  }
  return count;
}

/** Parses and inspects `text`. Throws {@link BadBodyError} if it isn't a JSON object. */
export function inspectBody(text: string): InspectedBody {
  if (text.trim() === "") return EMPTY_BODY;
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new BadBodyError("body is not valid JSON");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new BadBodyError("body must be a JSON object");
  }
  const sessionIds = new Set<string>();
  walk(parsed, 0, sessionIds);
  return {
    json: JSON.stringify(parsed),
    sessionIds,
    remoteEntriesWithoutSessionId: countRemoteWithoutSessionId(
      parsed as Record<string, unknown>,
    ),
  };
}
