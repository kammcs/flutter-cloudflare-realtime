/**
 * Entry point: `npm start -- [--host 0.0.0.0] [--port 8787]`.
 *
 * DEV ONLY. See ../README.md.
 */

import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import {
  describeSettings,
  isLoopback,
  lanAddresses,
  loadEnv,
  parseCli,
  resolveConfig,
  USAGE,
} from "./config.ts";
import { createDevServer, HEALTH_PATH, SIGNALING_PATH } from "./server.ts";

const BANNER = [
  "================================================================",
  "  cloudflare_realtime DEV SERVER: DEV ONLY, NOT FOR PRODUCTION",
  "  One shared token, self-declared users, every room open to all.",
  "================================================================",
].join("\n");

async function main(): Promise<number> {
  let args;
  try {
    args = parseCli(process.argv.slice(2));
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    console.error(USAGE);
    return 2;
  }
  if (args.help) {
    console.log(USAGE);
    return 0;
  }

  console.log(BANNER);
  const toolDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const envPath = resolve(toolDir, args.envFile);
  const { env, fromFile } = loadEnv(process.env, envPath);
  console.log(fromFile ? `Read ${args.envFile} (environment variables take precedence).` : `No ${args.envFile} file; using the environment.`);
  console.log("Settings:");
  for (const line of describeSettings(env)) console.log(line);

  const result = resolveConfig(env);
  if (!result.ok) {
    console.error("\nRefusing to start:");
    for (const e of result.errors) console.error(`  - ${e}`);
    return 1;
  }
  const config = result.config;

  const server = createDevServer({
    appId: config.appId,
    appSecret: config.appSecret,
    ...(config.turn ? { turn: config.turn } : {}),
    devToken: config.devToken,
    corsOrigins: config.corsOrigins,
    ...(args.heartbeatMs ? { heartbeatMs: args.heartbeatMs } : {}),
    log: (m) => console.log(`${new Date().toISOString()} ${m}`),
  });
  const address = await server.listen(args.port, args.host);

  const hosts = isLoopback(args.host)
    ? [args.host.includes(":") ? `[${args.host}]` : args.host]
    : args.host === "0.0.0.0" || args.host === "::"
    ? ["127.0.0.1", ...lanAddresses()]
    : [args.host];
  console.log(`\nListening on ${args.host}:${address.port}`);
  if (!isLoopback(args.host)) {
    console.warn(
      "\nWARNING: bound beyond this machine. Anyone on this network who learns the dev token can\n" +
        "use your Cloudflare SFU app. Use it on a trusted network only, and stop the server when done.",
    );
  }
  console.log(`\nDev token${config.devTokenGenerated ? " (random, new at each start)" : ""}: ${
    config.devTokenGenerated ? config.devToken : "(from DEV_TOKEN)"
  }`);
  console.log("\nIn the example app's join screen, use one of:");
  for (const h of hosts) console.log(`  Server URL: http://${h}:${address.port}`);
  console.log(`\nBroker base URL = server URL; signaling = ws://<host>:${address.port}${SIGNALING_PATH}?token=<dev token>`);
  console.log(`Health check: http://<host>:${address.port}${HEALTH_PATH}`);
  console.log("TURN:", config.turn ? "configured" : "not configured (STUN only)");
  console.log("\nPress Ctrl+C to stop.\n");

  await new Promise<void>((resolveStop) => {
    const stop = () => resolveStop();
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  });
  console.log("Stopping...");
  await server.close();
  return 0;
}

main().then(
  (code) => process.exit(code),
  (e: unknown) => {
    // Error messages here come from Node (bind failures and the like), not from secrets.
    console.error(e instanceof Error ? e.message : String(e));
    process.exit(1);
  },
);
