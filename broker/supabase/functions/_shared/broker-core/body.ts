/**
 * Request body inspection for rule 4 (same-room pulls) and for the optional
 * `authorizeDataChannels` hook.
 *
 * The broker parses every JSON body, collects each `sessionId` it names (at any
 * depth: `tracks[]`, `dataChannels[]`, `dataChannel`, and anything the SFU API
 * adds later), and forwards its own re-serialization of the parsed value. So
 * what Cloudflare receives is exactly what was checked; duplicate keys and
 * other parser differentials can't smuggle a different `sessionId` through.
 */

import type { DataChannelEntry } from "./types.ts";

/** Keys the broker reasons about, which must use their exact spelling. */
const CANONICAL_KEYS = [
  "sessionId",
  "tracks",
  "dataChannels",
  "dataChannel",
  "location",
  "dataChannelName",
  "canReply",
  "id",
];

/**
 * Folds `key` the way case-insensitive JSON decoders compare names. Go's
 * `encoding/json`, for one, uses Unicode simple case folding, under which
 * `ſ` (U+017F) matches `s` and the Kelvin sign `K` (U+212A) matches `k`.
 * `toLowerCase` already maps the Kelvin sign to `k`, but leaves `ſ`.
 */
function foldKey(key: string): string {
  return key.toLowerCase().replace(/\u017f/g, "s");
}

const CANONICAL_BY_FOLDED = new Map(CANONICAL_KEYS.map((k) => [foldKey(k), k]));

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
  /** The parsed value that {@link json} serializes, or `null` without a body. */
  readonly value: Readonly<Record<string, unknown>> | null;
}

/** The result for a request without a body. */
export const EMPTY_BODY: InspectedBody = {
  json: null,
  sessionIds: new Set(),
  remoteEntriesWithoutSessionId: 0,
  value: null,
};

function walk(value: unknown, depth: number, found: Set<string>): void {
  if (depth > MAX_DEPTH) throw new BadBodyError("body is nested too deeply");
  if (Array.isArray(value)) {
    for (const item of value) walk(item, depth + 1, found);
    return;
  }
  if (typeof value !== "object" || value === null) return;
  for (const [key, child] of Object.entries(value)) {
    const canonical = CANONICAL_BY_FOLDED.get(foldKey(key));
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
    value: parsed as Record<string, unknown>,
  };
}

/**
 * The DataChannels named in `body` (the `dataChannel` object, then each entry
 * of `dataChannels`), as frozen copies of the fields in {@link DataChannelEntry}.
 * Both fields are read whatever the route, so the result covers everything the
 * SFU could act on. Throws {@link BadBodyError} for a field of the wrong type.
 */
export function dataChannelEntries(body: InspectedBody): readonly DataChannelEntry[] {
  const value = body.value;
  if (value === null) return Object.freeze([]);
  const raw: unknown[] = [];
  const single = value["dataChannel"];
  if (single !== undefined) raw.push(single);
  const list = value["dataChannels"];
  if (list !== undefined) {
    // inspectBody already refused a non-array.
    if (!Array.isArray(list)) throw new BadBodyError("dataChannels must be an array");
    raw.push(...list);
  }
  return Object.freeze(raw.map(toEntry));
}

function toEntry(raw: unknown): DataChannelEntry {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new BadBodyError("DataChannel entries must be objects");
  }
  const e = raw as Record<string, unknown>;
  const entry: {
    location?: "local" | "remote";
    dataChannelName?: string;
    sessionId?: string;
    canReply?: boolean;
    id?: number;
  } = {};
  const { location, dataChannelName, sessionId, canReply, id } = e;
  if (location !== undefined) {
    if (location !== "local" && location !== "remote") {
      throw new BadBodyError("location must be \"local\" or \"remote\"");
    }
    entry.location = location;
  }
  if (dataChannelName !== undefined) {
    if (typeof dataChannelName !== "string") throw new BadBodyError("dataChannelName must be a string");
    entry.dataChannelName = dataChannelName;
  }
  if (sessionId !== undefined) {
    if (typeof sessionId !== "string") throw new BadBodyError("sessionId must be a string");
    entry.sessionId = sessionId;
  }
  if (canReply !== undefined) {
    if (typeof canReply !== "boolean") throw new BadBodyError("canReply must be a boolean");
    entry.canReply = canReply;
  }
  if (id !== undefined) {
    if (typeof id !== "number" || !Number.isInteger(id)) throw new BadBodyError("id must be an integer");
    entry.id = id;
  }
  return Object.freeze(entry);
}
