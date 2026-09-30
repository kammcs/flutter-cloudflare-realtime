/**
 * `authenticate` hook for Supabase: the caller sends its Supabase access
 * token as `Authorization: Bearer <JWT>`, and the function checks it with the
 * Auth server (`supabase.auth.getUser(jwt)`). The caller ID is the user's ID.
 *
 * No Deno or supabase-js import here, so it can be unit-tested; the Edge
 * Function passes `(jwt) => supabase.auth.getUser(jwt)`.
 */

import type { Caller } from "../_shared/broker-core/mod.ts";

/** The part of `supabase.auth.getUser` the hook uses. */
export type GetUser = (
  jwt: string,
) => PromiseLike<{ data: { user: { id: string } | null }; error: unknown }>;

/** Creates an `authenticate` hook that returns `null` for any missing or invalid token. */
export function createSupabaseAuthenticator(getUser: GetUser): (request: Request) => Promise<Caller | null> {
  return async (request) => {
    const header = request.headers.get("Authorization");
    const match = header ? /^Bearer\s+(\S+)$/i.exec(header) : null;
    if (!match) return null;
    try {
      const { data, error } = await getUser(match[1]!);
      if (error || !data.user || typeof data.user.id !== "string" || data.user.id === "") {
        return null;
      }
      return { id: data.user.id };
    } catch {
      return null;
    }
  };
}
