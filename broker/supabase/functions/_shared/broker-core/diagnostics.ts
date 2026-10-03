import type { BrokerErrorInfo } from "./types.ts";

/** One identifier-like token: an error `code` or `name`, never free text. */
const SAFE_TOKEN = /^[A-Za-z][A-Za-z0-9_.-]{0,63}$/;
/** How many `cause` links to follow. */
const MAX_DEPTH = 4;

/**
 * Describes why an upstream call failed by the error's `code` or `name` only,
 * following its `cause` chain: for example `TypeError: UND_ERR_CONNECT_TIMEOUT`
 * (Node's fetch, connect timeout), `TypeError: ENOTFOUND` (DNS),
 * `TimeoutError` (an `AbortSignal.timeout`), or `TypeError` (Deno).
 *
 * Messages are never included: they can carry URLs (the App ID), and on some
 * runtimes more. Each token must look like an identifier, so nothing else can
 * leak through a crafted `code`. Returns `undefined` when there is nothing
 * safe to say.
 */
export function errorCause(error: unknown): string | undefined {
  const tokens: string[] = [];
  let current: unknown = error;
  for (let depth = 0; depth < MAX_DEPTH && typeof current === "object" && current !== null; depth++) {
    const e = current as { code?: unknown; name?: unknown; cause?: unknown };
    const token = typeof e.code === "string" && SAFE_TOKEN.test(e.code)
      ? e.code
      : typeof e.name === "string" && SAFE_TOKEN.test(e.name)
      ? e.name
      : undefined;
    if (token !== undefined && tokens[tokens.length - 1] !== token) tokens.push(token);
    current = e.cause;
  }
  return tokens.length > 0 ? tokens.join(": ") : undefined;
}

/**
 * Formats a {@link BrokerErrorInfo} as one log line, for example
 * `sessions/new: SFU request failed (TypeError: ENOTFOUND, after 12 ms)`.
 * Everything in it is already sanitized.
 */
export function formatBrokerError(info: BrokerErrorInfo): string {
  const details = [
    ...(info.cause !== undefined ? [info.cause] : []),
    ...(info.elapsedMs !== undefined ? [`after ${Math.round(info.elapsedMs)} ms`] : []),
  ];
  return `${info.route}: ${info.message}${details.length > 0 ? ` (${details.join(", ")})` : ""}`;
}
