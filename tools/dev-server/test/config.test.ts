import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { describeSettings, isLoopback, loadEnv, parseCli, resolveConfig } from "../src/config.ts";

// Fake, test-only values.
const BASE = { REALTIME_DEV_SERVER: "1", CF_REALTIME_APP_ID: "app", CF_REALTIME_APP_SECRET: "not-a-real-secret" };

describe("resolveConfig", () => {
  it("refuses to start without REALTIME_DEV_SERVER=1", () => {
    for (const flag of [undefined, "", "0", "true"]) {
      const r = resolveConfig({ ...BASE, REALTIME_DEV_SERVER: flag });
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.errors.join()).toContain("REALTIME_DEV_SERVER=1");
    }
  });

  it("requires the SFU credentials and never echoes their values", () => {
    const r = resolveConfig({ REALTIME_DEV_SERVER: "1", CF_REALTIME_APP_SECRET: "  " });
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.errors.join()).toContain("CF_REALTIME_APP_ID");
      expect(r.errors.join()).toContain("CF_REALTIME_APP_SECRET");
    }
  });

  it("requires both TURN settings or neither", () => {
    expect(resolveConfig({ ...BASE, CF_TURN_KEY_ID: "k" }).ok).toBe(false);
    const r = resolveConfig({ ...BASE, CF_TURN_KEY_ID: "k", CF_TURN_API_TOKEN: "t" });
    expect(r.ok && r.config.turn).toEqual({ keyId: "k", apiToken: "t" });
  });

  it("generates a random dev token unless DEV_TOKEN is set", () => {
    const a = resolveConfig(BASE);
    const b = resolveConfig(BASE);
    expect(a.ok && b.ok).toBe(true);
    if (a.ok && b.ok) {
      expect(a.config.devTokenGenerated).toBe(true);
      expect(a.config.devToken.length).toBeGreaterThanOrEqual(32);
      expect(a.config.devToken).not.toBe(b.config.devToken);
    }
    const fixed = resolveConfig({ ...BASE, DEV_TOKEN: "a-fixed-dev-token-123" });
    expect(fixed.ok && fixed.config.devToken).toBe("a-fixed-dev-token-123");
    expect(fixed.ok && fixed.config.devTokenGenerated).toBe(false);
    expect(resolveConfig({ ...BASE, DEV_TOKEN: "short" }).ok).toBe(false);
  });

  it("defaults CORS to any origin and accepts a list", () => {
    const any = resolveConfig(BASE);
    expect(any.ok && any.config.corsOrigins).toBe("*");
    const list = resolveConfig({ ...BASE, DEV_CORS_ORIGINS: "http://localhost:5000/, http://a.test" });
    expect(list.ok && list.config.corsOrigins).toEqual(["http://localhost:5000", "http://a.test"]);
  });
});

describe("describeSettings", () => {
  it("says set or not set, never the value", () => {
    const lines = describeSettings({ ...BASE, CF_TURN_KEY_ID: "" }).join("\n");
    expect(lines).toMatch(/CF_REALTIME_APP_SECRET\s+set/);
    expect(lines).toMatch(/CF_TURN_KEY_ID\s+not set/);
    expect(lines).not.toContain("not-a-real-secret");
  });
});

describe("loadEnv", () => {
  it("merges the file under the real environment", () => {
    const dir = mkdtempSync(join(tmpdir(), "dev-server-"));
    try {
      const path = join(dir, ".env");
      writeFileSync(path, "CF_REALTIME_APP_ID=from-file\nCF_REALTIME_APP_SECRET=file-secret\n");
      const { env, fromFile } = loadEnv({ CF_REALTIME_APP_ID: "from-env" }, path);
      expect(fromFile).toBe(true);
      expect(env.CF_REALTIME_APP_ID).toBe("from-env");
      expect(env.CF_REALTIME_APP_SECRET).toBe("file-secret");
      expect(loadEnv({}, join(dir, "missing")).fromFile).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("parseCli", () => {
  it("binds to loopback by default", () => {
    const args = parseCli([]);
    expect(args.host).toBe("127.0.0.1");
    expect(args.port).toBe(8787);
    expect(isLoopback(args.host)).toBe(true);
  });

  it("accepts an explicit wider host", () => {
    const args = parseCli(["--host", "0.0.0.0", "--port", "9000"]);
    expect(args.host).toBe("0.0.0.0");
    expect(args.port).toBe(9000);
    expect(isLoopback(args.host)).toBe(false);
  });

  it("rejects bad input", () => {
    expect(() => parseCli(["--port", "x"])).toThrow();
    expect(() => parseCli(["--heartbeat-ms", "5"])).toThrow();
    expect(() => parseCli(["--unknown"])).toThrow();
  });
});
