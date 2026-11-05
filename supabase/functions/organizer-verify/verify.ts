// organizer-verify: the DNS TXT proof of an organizer claim (migration 62, design 2.3). Pure logic
// with injected I/O, so verify_test.ts runs without network or secrets.
//
// The owner asks for a check; the claim (organizer_claim_check, called with the owner's own JWT,
// so ownership is checked in the database) gives the record name _activityplanet.<registrable
// domain> and the token. The record is read through Cloudflare's public DNS-over-HTTPS JSON API
// (no key, no account). Only the resolver is contacted, never the claimed host, so this opens no
// path from the Edge runtime to an address the organizer chooses. The outcome goes to
// collector_claims_record (service role): verified, or dns_no_txt (one attempt; 10 fail the
// claim). A resolver error or timeout records nothing: the claim stays pending and costs no try.

export const DOH = "https://cloudflare-dns.com/dns-query";
const TOKEN = /^ap-verify-[a-z2-7]{24}$/;
const NAME = /^_activityplanet\.([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$/;

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export function dohUrl(name: string): string {
  const u = new URL(DOH);
  u.searchParams.set("name", name);
  u.searchParams.set("type", "TXT");
  return u.toString();
}

/** The TXT strings of a DoH JSON answer: quoted parts of one record joined, as RFC 7208 reads them. */
export function txtValues(answer: unknown): string[] {
  const a = (answer ?? {}) as { Answer?: unknown };
  const out: string[] = [];
  for (const r of Array.isArray(a.Answer) ? a.Answer : []) {
    const o = (r ?? {}) as { type?: unknown; data?: unknown };
    if (o.type !== 16 || typeof o.data !== "string") continue;
    const parts = [...o.data.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) =>
      m[1]!.replace(/\\(.)/g, "$1"),
    );
    out.push(parts.length > 0 ? parts.join("") : o.data);
  }
  return out;
}

export type DnsOutcome =
  | { kind: "verified" }
  | { kind: "dns_no_txt"; reason: "nxdomain" | "no_txt" | "wrong_token" }
  | { kind: "resolver_error" };

/** Reads the record once. */
export async function checkDns(
  name: string,
  token: string,
  fetchImpl: FetchLike,
): Promise<DnsOutcome> {
  let res: Response;
  try {
    res = await fetchImpl(dohUrl(name), {
      headers: { accept: "application/dns-json" },
      signal: AbortSignal.timeout(8000),
    });
  } catch {
    return { kind: "resolver_error" };
  }
  if (!res.ok) {
    await res.body?.cancel();
    return { kind: "resolver_error" };
  }
  let body: { Status?: unknown };
  try {
    body = await res.json();
  } catch {
    return { kind: "resolver_error" };
  }
  if (body.Status === 3) return { kind: "dns_no_txt", reason: "nxdomain" };
  if (body.Status !== 0) return { kind: "resolver_error" };
  const values = txtValues(body);
  if (values.length === 0) return { kind: "dns_no_txt", reason: "no_txt" };
  return values.some((v) => v.trim() === token)
    ? { kind: "verified" }
    : { kind: "dns_no_txt", reason: "wrong_token" };
}

export interface Deps {
  /** organizer_claim_check with the caller's own JWT. */
  claimCheck: (claimId: string) => Promise<Record<string, unknown>>;
  /** collector_claims_record with the service role. */
  record: (results: Record<string, unknown>[]) => Promise<unknown>;
  fetch: FetchLike;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export async function handleVerify(
  body: unknown,
  deps: Deps,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const claimId = (body as { claim_id?: unknown } | null)?.claim_id;
  if (typeof claimId !== "string" || !UUID.test(claimId))
    return { status: 400, body: { error: "invalid_claim" } };
  const claim = await deps.claimCheck(claimId);
  if (claim.status !== "pending")
    return { status: 200, body: { status: claim.status ?? "unknown" } };
  if (claim.method !== "dns_txt")
    return { status: 200, body: { status: "pending", checked: "queued" } };
  const name = typeof claim.dns_name === "string" ? claim.dns_name : "";
  const token = typeof claim.token === "string" ? claim.token : "";
  if (!NAME.test(name) || !TOKEN.test(token))
    return { status: 200, body: { status: "pending", checked: "invalid" } };
  const out = await checkDns(name, token, deps.fetch);
  if (out.kind === "resolver_error")
    return { status: 200, body: { status: "pending", checked: "resolver_error" } };
  await deps.record([
    out.kind === "verified"
      ? { claim_id: claimId, outcome: "verified", method: "dns_txt" }
      : { claim_id: claimId, outcome: "dns_no_txt", method: "dns_txt", reason: out.reason },
  ]);
  return {
    status: 200,
    body:
      out.kind === "verified" ? { status: "verified" } : { status: "pending", checked: out.reason },
  };
}
