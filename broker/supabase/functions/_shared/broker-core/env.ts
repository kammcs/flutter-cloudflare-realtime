/** Small helpers for reading string settings from environment variables. */

/** Splits a comma-separated list, trimming blanks. `"*"` stays a single entry. */
export function parseList(value: string | undefined): string[] {
  return (value ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s !== "");
}

/** Parses a positive integer, or returns `fallback` when unset or invalid. */
export function parsePositiveInt(value: string | undefined, fallback: number): number {
  if (value === undefined || value.trim() === "") return fallback;
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

/**
 * Parses an allowed-origins setting: `"*"`, or a comma-separated list of
 * exact origins. Returns `undefined` when unset, which disables browser access.
 */
export function parseAllowedOrigins(value: string | undefined): "*" | string[] | undefined {
  const list = parseList(value);
  if (list.length === 0) return undefined;
  if (list.includes("*")) return "*";
  return list.map((o) => o.replace(/\/+$/, ""));
}
