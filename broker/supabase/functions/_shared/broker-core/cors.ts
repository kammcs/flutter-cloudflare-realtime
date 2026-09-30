import type { CorsConfig } from "./types.ts";

/** Headers every client of the contract may send. */
export const DEFAULT_ALLOWED_HEADERS: readonly string[] = [
  "authorization",
  "content-type",
  "x-realtime-room",
  "x-realtime-session-token",
];

/** Response headers a browser client must be able to read. */
export const EXPOSED_HEADERS: readonly string[] = ["x-realtime-session-token"];

const ALLOWED_METHODS = "GET, POST, PUT, OPTIONS";

/** Whether `origin` is allowed. A request without `Origin` (native clients) is always allowed. */
export function isOriginAllowed(origin: string | null, cors: CorsConfig | undefined): boolean {
  if (origin === null) return true;
  if (!cors) return false;
  if (cors.allowedOrigins === "*") return true;
  return cors.allowedOrigins.includes(origin);
}

/** CORS headers for an actual (non-preflight) response to an allowed origin. */
export function corsResponseHeaders(
  origin: string | null,
  cors: CorsConfig | undefined,
): Record<string, string> {
  if (origin === null || !cors || !isOriginAllowed(origin, cors)) return {};
  return {
    "Access-Control-Allow-Origin": cors.allowedOrigins === "*" ? "*" : origin,
    "Access-Control-Expose-Headers": EXPOSED_HEADERS.join(", "),
    "Vary": "Origin",
  };
}

/** Builds the response to an `OPTIONS` preflight. */
export function preflightResponse(request: Request, cors: CorsConfig | undefined): Response {
  const origin = request.headers.get("Origin");
  if (!cors || origin === null || !isOriginAllowed(origin, cors)) {
    return new Response(null, { status: 403, headers: { "Vary": "Origin" } });
  }
  const allowedHeaders = [
    ...DEFAULT_ALLOWED_HEADERS,
    ...(cors.extraAllowedHeaders ?? []).map((h) => h.toLowerCase()),
  ];
  return new Response(null, {
    status: 204,
    headers: {
      "Access-Control-Allow-Origin": cors.allowedOrigins === "*" ? "*" : origin,
      "Access-Control-Allow-Methods": ALLOWED_METHODS,
      "Access-Control-Allow-Headers": [...new Set(allowedHeaders)].join(", "),
      "Access-Control-Max-Age": String(cors.maxAgeSeconds ?? 600),
      "Vary": "Origin",
    },
  });
}
