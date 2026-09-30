/** Command line and environment handling for the dev server. */

import { existsSync, readFileSync } from "node:fs";
import { networkInterfaces } from "node:os";
import { parseArgs, parseEnv } from "node:util";
import type { TurnConfig } from "../../../broker/supabase/functions/_shared/broker-core/mod.ts";
import { parseAllowedOrigins } from "../../../broker/supabase/functions/_shared/broker-core/mod.ts";
import { generateDevToken, MIN_DEV_TOKEN_LENGTH } from "./dev_auth.ts";

export const DEFAULT_HOST = "127.0.0.1";
export const DEFAULT_PORT = 8787;

/** Parsed command line. */
export interface CliArgs {
  readonly host: string;
  readonly port: number;
  readonly envFile: string;
  readonly heartbeatMs: number | undefined;
  readonly help: boolean;
}

export const USAGE = `Usage: npm start -- [--host 127.0.0.1] [--port ${DEFAULT_PORT}] [--env-file .env] [--heartbeat-ms 2000]

DEV ONLY local broker + presence signaling for cloudflare_realtime.
Requires REALTIME_DEV_SERVER=1, CF_REALTIME_APP_ID and CF_REALTIME_APP_SECRET
(in the environment or the .env file). See README.md.

  --host          Interface to bind. Default ${DEFAULT_HOST} (this machine only).
                  Use --host 0.0.0.0 to let phones and other computers on your LAN connect.
  --port          TCP port. Default ${DEFAULT_PORT}.
  --env-file      Env file to read (real environment variables win). Default .env.
  --heartbeat-ms  Signaling ping interval; dead sockets leave within ~2x. Default 2000.`;

/** Parses `argv` (without the node and script entries). Throws on bad input. */
export function parseCli(argv: readonly string[]): CliArgs {
  const { values } = parseArgs({
    args: [...argv],
    options: {
      host: { type: "string", default: DEFAULT_HOST },
      port: { type: "string", default: String(DEFAULT_PORT) },
      "env-file": { type: "string", default: ".env" },
      "heartbeat-ms": { type: "string" },
      help: { type: "boolean", short: "h", default: false },
    },
    strict: true,
    allowPositionals: false,
  });
  const port = Number(values.port);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error(`invalid --port: ${values.port}`);
  let heartbeatMs: number | undefined;
  if (values["heartbeat-ms"] !== undefined) {
    heartbeatMs = Number(values["heartbeat-ms"]);
    if (!Number.isInteger(heartbeatMs) || heartbeatMs < 100) throw new Error("--heartbeat-ms must be an integer >= 100");
  }
  return { host: values.host!, port, envFile: values["env-file"]!, heartbeatMs, help: values.help! };
}

/**
 * Reads `path` if it exists and merges it under `env`: real environment
 * variables win over the file.
 */
export function loadEnv(env: NodeJS.ProcessEnv, path: string): { env: Record<string, string | undefined>; fromFile: boolean } {
  if (!existsSync(path)) return { env: { ...env }, fromFile: false };
  const fileVars = parseEnv(readFileSync(path, "utf8"));
  return { env: { ...fileVars, ...env }, fromFile: true };
}

/** Everything the server needs, resolved from the environment. */
export interface ResolvedConfig {
  readonly appId: string;
  readonly appSecret: string;
  readonly turn?: TurnConfig;
  readonly devToken: string;
  /** Whether {@link devToken} was generated (and so may be printed). */
  readonly devTokenGenerated: boolean;
  readonly corsOrigins: "*" | string[];
}

/** Result of {@link resolveConfig}: a config, or the reasons it can't start. */
export type ConfigResult = { ok: true; config: ResolvedConfig } | { ok: false; errors: string[] };

const set = (v: string | undefined): v is string => v !== undefined && v.trim() !== "";

/** Validates the environment. Never includes secret values in its messages. */
export function resolveConfig(env: Record<string, string | undefined>): ConfigResult {
  const errors: string[] = [];
  if (env.REALTIME_DEV_SERVER !== "1") {
    errors.push("REALTIME_DEV_SERVER=1 is not set. This server is for local development only; set it to confirm.");
  }
  if (!set(env.CF_REALTIME_APP_ID)) errors.push("CF_REALTIME_APP_ID is not set.");
  if (!set(env.CF_REALTIME_APP_SECRET)) errors.push("CF_REALTIME_APP_SECRET is not set.");
  if (set(env.CF_TURN_KEY_ID) !== set(env.CF_TURN_API_TOKEN)) {
    errors.push("Set both CF_TURN_KEY_ID and CF_TURN_API_TOKEN, or neither.");
  }
  if (set(env.DEV_TOKEN) && env.DEV_TOKEN.trim().length < MIN_DEV_TOKEN_LENGTH) {
    errors.push(`DEV_TOKEN must be at least ${MIN_DEV_TOKEN_LENGTH} characters.`);
  }
  if (set(env.DEV_TOKEN) && /\s/.test(env.DEV_TOKEN.trim())) errors.push("DEV_TOKEN must not contain spaces.");
  if (errors.length > 0) return { ok: false, errors };

  const devTokenGenerated = !set(env.DEV_TOKEN);
  return {
    ok: true,
    config: {
      appId: env.CF_REALTIME_APP_ID!.trim(),
      appSecret: env.CF_REALTIME_APP_SECRET!.trim(),
      ...(set(env.CF_TURN_KEY_ID)
        ? { turn: { keyId: env.CF_TURN_KEY_ID.trim(), apiToken: env.CF_TURN_API_TOKEN!.trim() } }
        : {}),
      devToken: devTokenGenerated ? generateDevToken() : env.DEV_TOKEN!.trim(),
      devTokenGenerated,
      corsOrigins: parseAllowedOrigins(env.DEV_CORS_ORIGINS) ?? "*",
    },
  };
}

/** One line per setting: whether it is set, never its value. */
export function describeSettings(env: Record<string, string | undefined>): string[] {
  const names = ["CF_REALTIME_APP_ID", "CF_REALTIME_APP_SECRET", "CF_TURN_KEY_ID", "CF_TURN_API_TOKEN", "DEV_TOKEN"];
  return names.map((n) => `  ${n.padEnd(24)} ${set(env[n]) ? "set" : "not set"}`);
}

/** Whether `host` only accepts connections from this machine. */
export function isLoopback(host: string): boolean {
  return host === "localhost" || host === "::1" || /^127\./.test(host);
}

/** This machine's non-internal IPv4 addresses, for LAN device setup. */
export function lanAddresses(): string[] {
  return Object.values(networkInterfaces())
    .flat()
    .filter((i) => i !== undefined && i.family === "IPv4" && !i.internal)
    .map((i) => i!.address);
}
