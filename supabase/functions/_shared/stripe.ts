// Shared by stripe-connect, stripe-checkout, stripe-webhook and delete-account (migration 60,
// docs/design/coaching/COACHING_DESIGN.md section 9). No Stripe SDK: a small form-encoded fetch
// client with the API version pinned, injected so the tests pass a mock and never touch the
// network. Logs carry ids and error names only (the Actions logs are public).

export const STRIPE_API = "https://api.stripe.com";
export const STRIPE_VERSION = "2024-06-20";

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export type Param = string | number | boolean | null | undefined | Params | Param[];
export interface Params {
  [key: string]: Param;
}

export interface StripeResult {
  ok: boolean;
  status: number;
  body: Record<string, unknown>;
}

export interface Stripe {
  request(
    method: "GET" | "POST" | "DELETE",
    path: string,
    params?: Params,
    idempotencyKey?: string,
  ): Promise<StripeResult>;
}

/** Stripe's form encoding: nested objects as a[b][c], arrays as a[0][b]; null/undefined left out. */
export function formEncode(params: Params, prefix = ""): string {
  const out: string[] = [];
  const walk = (value: Param, key: string) => {
    if (value === null || value === undefined) return;
    if (Array.isArray(value)) {
      value.forEach((v, i) => walk(v, `${key}[${i}]`));
    } else if (typeof value === "object") {
      for (const [k, v] of Object.entries(value)) walk(v, key ? `${key}[${k}]` : k);
    } else {
      out.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`);
    }
  };
  walk(params, prefix);
  return out.join("&");
}

export function createStripe(secretKey: string, fetchImpl: FetchLike = fetch): Stripe {
  return {
    async request(method, path, params, idempotencyKey) {
      const headers: Record<string, string> = {
        Authorization: `Bearer ${secretKey}`,
        "Stripe-Version": STRIPE_VERSION,
      };
      let url = `${STRIPE_API}${path}`;
      let body: string | undefined;
      const encoded = params ? formEncode(params) : "";
      if (method === "POST") {
        headers["Content-Type"] = "application/x-www-form-urlencoded";
        body = encoded;
        if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
      } else if (encoded) {
        url += `?${encoded}`;
      }
      const res = await fetchImpl(url, { method, headers, body });
      let parsed: Record<string, unknown> = {};
      try {
        const text = await res.text();
        parsed = text ? (JSON.parse(text) as Record<string, unknown>) : {};
      } catch {
        parsed = {};
      }
      return { ok: res.ok, status: res.status, body: parsed };
    },
  };
}

/** test or live from the secret key's prefix (sk_ or rk_); null when unknown. */
export function keyMode(secretKey: string | undefined): "live" | "test" | null {
  if (!secretKey) return null;
  if (/^(sk|rk)_live_/.test(secretKey)) return "live";
  if (/^(sk|rk)_test_/.test(secretKey)) return "test";
  return null;
}

/** The Stripe error code or type, never the message (it can name a person or an amount). */
export function stripeErrorName(result: StripeResult): string {
  const err = result.body?.error as { code?: unknown; type?: unknown } | undefined;
  const name =
    typeof err?.code === "string" ? err.code : typeof err?.type === "string" ? err.type : "";
  return `stripe_${result.status}${name ? `_${name}` : ""}`.slice(0, 80);
}

export const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

/** The key gate's answer: payments are not set up on this project (requests-only mode). */
export const PAYMENTS_OFF = {
  error: "payments_off",
  message:
    "In-app payments are not set up. Bookings still work as requests, and payment is arranged directly with the coach.",
} as const;

export function paymentsOff(): Response {
  return json(PAYMENTS_OFF, 503);
}

export type Rpc = (name: string, args: Record<string, unknown>) => Promise<unknown>;

export class RpcError extends Error {
  constructor(
    public readonly rpcName: string,
    public readonly status: number,
    public readonly code: string,
  ) {
    super(`rpc_${rpcName}_${status}_${code}`);
  }
}

/** PostgREST RPC as the service role. The database error message (our error codes) is kept. */
export function createRpc(
  supabaseUrl: string,
  serviceKey: string,
  fetchImpl: FetchLike = fetch,
): Rpc {
  return async (name, args) => {
    const res = await fetchImpl(`${supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(args),
    });
    const text = await res.text();
    if (!res.ok) {
      let code = "error";
      try {
        const m = (JSON.parse(text) as { message?: unknown }).message;
        if (typeof m === "string" && /^[a-z_]{2,40}$/.test(m)) code = m;
      } catch {
        // keep "error"
      }
      throw new RpcError(name, res.status, code);
    }
    return text ? JSON.parse(text) : null;
  };
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The key gate every Stripe function runs first: the payments_off answer when any of the named
 * secrets is missing or empty, else null (go on).
 */
export function keyGate(
  env: (name: string) => string | undefined,
  names: string[],
): Response | null {
  return names.every((n) => (env(n) ?? "").length > 0) ? null : paymentsOff();
}
