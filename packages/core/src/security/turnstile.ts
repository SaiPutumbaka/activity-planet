/**
 * Cloudflare Turnstile for the public request forms (apps/web /api/takedown and
 * /api/listing-removal), shared so both behave the same (launch audit L9):
 *   - with TURNSTILE_SECRET_KEY set, the token must verify AND the answer's hostname must be one
 *     of this site's hosts (a token solved on another site that uses the same widget is refused);
 *   - without the secret, production (VERCEL_ENV=production) fails closed; previews and local
 *     development let requests through so the forms can be tested.
 */
export const TURNSTILE_VERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export interface TurnstileEnv {
  secret: string | undefined;
  vercelEnv: string | undefined;
  /** Hosts a token may come from; empty skips the check (should not happen in production). */
  hostnames: string[];
}

export type TurnstileResult = "ok" | "missing_token" | "failed" | "wrong_host" | "not_configured";

export async function verifyTurnstile(
  token: unknown,
  ip: string | null,
  env: TurnstileEnv,
  fetchImpl: FetchLike = fetch,
): Promise<TurnstileResult> {
  if (!env.secret) return env.vercelEnv === "production" ? "not_configured" : "ok";
  if (typeof token !== "string" || token === "" || token.length > 2048) return "missing_token";
  const form = new URLSearchParams({ secret: env.secret, response: token });
  if (ip) form.set("remoteip", ip);
  try {
    const res = await fetchImpl(TURNSTILE_VERIFY, { method: "POST", body: form });
    const answer = (await res.json()) as { success?: boolean; hostname?: unknown };
    if (answer.success !== true) return "failed";
    if (env.hostnames.length > 0) {
      const host = typeof answer.hostname === "string" ? answer.hostname.toLowerCase() : "";
      if (!env.hostnames.includes(host)) return "wrong_host";
    }
    return "ok";
  } catch {
    return "failed";
  }
}

/** The hosts of the given origins (bad or empty entries are skipped), lower case, unique. */
export function hostsOf(...origins: (string | null | undefined)[]): string[] {
  const out = new Set<string>();
  for (const o of origins) {
    for (const part of (o ?? "").split(",")) {
      const t = part.trim();
      if (!t) continue;
      try {
        out.add(new URL(t.includes("://") ? t : `https://${t}`).hostname.toLowerCase());
      } catch {
        /* skip */
      }
    }
  }
  return [...out];
}

/** The caller's address as Vercel reports it (the first x-forwarded-for hop), or null. */
export function clientIp(headers: Headers): string | null {
  const forwarded = headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return forwarded || headers.get("x-real-ip")?.trim() || null;
}
