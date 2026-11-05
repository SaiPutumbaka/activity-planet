// eventbrite-connect (migration 62, design 2.8): an organizer connects their own Eventbrite
// account through Eventbrite's OAuth API, and the nightly job reads their live events through the
// documented organizer endpoints. Key-gated: without EVENTBRITE_CLIENT_ID,
// EVENTBRITE_CLIENT_SECRET and EVENTBRITE_REDIRECT_URI (the app page Eventbrite sends the person
// back to) every request answers 200 {skipped: "no key"} and nothing is asked of Eventbrite.
// Pure logic with injected I/O, so connect_test.ts runs without network or keys.
//
//   {op: "status"}                       anyone: {available} (the app shows the button only then)
//   {op: "start"}                        signed in: a state bound to the person (10 minutes, single
//                                        use; only its SHA-256 is stored) and the authorize URL
//   {op: "callback", code, state}        signed in: the state must be this person's, unused and
//                                        unexpired; the code is exchanged for a token, kept in
//                                        Supabase Vault (organizer_eventbrite_store), never logged
//   {op: "sync"}                         the collector job (x-collector-secret): each connected
//                                        account's live events, posted like any collector source
//
// D-040 keeps Eventbrite's web pages and search off limits; only the OAuth endpoints on
// www.eventbrite.com/oauth and the API on www.eventbriteapi.com/v3 are called, for people who
// connected their own account, one request per 2 seconds. Eventbrite has no token revocation
// endpoint: on account deletion the token leaves the vault and the person can remove the app in
// their Eventbrite account settings.

export const AUTHORIZE = "https://www.eventbrite.com/oauth/authorize";
export const TOKEN_URL = "https://www.eventbrite.com/oauth/token";
export const API = "https://www.eventbriteapi.com/v3";
export const SPACING_MS = 2000;
const MAX_PAGES = 5;

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;
export type Rpc = (name: string, args: Record<string, unknown>) => Promise<unknown>;

export interface Keys {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
}

export function keysFrom(env: (name: string) => string | undefined): Keys | null {
  const clientId = (env("EVENTBRITE_CLIENT_ID") ?? "").trim();
  const clientSecret = (env("EVENTBRITE_CLIENT_SECRET") ?? "").trim();
  const redirectUri = (env("EVENTBRITE_REDIRECT_URI") ?? "").trim();
  if (!clientId || !clientSecret || !/^https:\/\//.test(redirectUri)) return null;
  return { clientId, clientSecret, redirectUri };
}

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function newState(): string {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

export function authorizeUrl(keys: Keys, state: string): string {
  const u = new URL(AUTHORIZE);
  u.searchParams.set("response_type", "code");
  u.searchParams.set("client_id", keys.clientId);
  u.searchParams.set("redirect_uri", keys.redirectUri);
  u.searchParams.set("state", state);
  return u.toString();
}

export interface Answer {
  status: number;
  body: Record<string, unknown>;
}

const SKIPPED: Answer = { status: 200, body: { skipped: "no key" } };

/** start and callback, for a signed-in person (userId from the verified JWT). */
export async function handleUser(
  userId: string,
  body: unknown,
  deps: { keys: Keys | null; rpc: Rpc; fetch: FetchLike; state?: () => string },
): Promise<Answer> {
  const o = (body ?? {}) as Record<string, unknown>;
  if (o.op === "status") return { status: 200, body: { available: deps.keys !== null } };
  if (!deps.keys) return SKIPPED;
  if (o.op === "start") {
    const state = (deps.state ?? newState)();
    await deps.rpc("organizer_oauth_start", {
      p_user: userId,
      p_state_hash: await sha256Hex(state),
    });
    return { status: 200, body: { url: authorizeUrl(deps.keys, state), expires_in: 600 } };
  }
  if (o.op === "callback") {
    if (typeof o.state !== "string" || !/^[0-9a-f]{64}$/.test(o.state))
      return { status: 400, body: { error: "invalid_state" } };
    if (typeof o.code !== "string" || !/^[A-Za-z0-9._-]{4,500}$/.test(o.code))
      return { status: 400, body: { error: "invalid_code" } };
    // Single use, bound to this person, 10 minutes: another person's state is refused.
    const taken = await deps.rpc("organizer_oauth_take", {
      p_user: userId,
      p_state_hash: await sha256Hex(o.state),
    });
    if (taken !== true) return { status: 403, body: { error: "invalid_state" } };
    const form = new URLSearchParams({
      grant_type: "authorization_code",
      client_id: deps.keys.clientId,
      client_secret: deps.keys.clientSecret,
      code: o.code,
      redirect_uri: deps.keys.redirectUri,
    });
    const res = await deps.fetch(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    let token: unknown = null;
    try {
      token = ((await res.json()) as { access_token?: unknown }).access_token;
    } catch {
      token = null;
    }
    if (!res.ok || typeof token !== "string")
      return { status: 502, body: { error: "exchange_failed" } };
    const stored = (await deps.rpc("organizer_eventbrite_store", {
      p_user: userId,
      p_token: token,
    })) as Record<string, unknown>;
    return { status: 200, body: { connected: true, source_id: stored?.source_id ?? null } };
  }
  return { status: 400, body: { error: "invalid_op" } };
}

type Obj = Record<string, unknown>;
const text = (v: unknown): string =>
  typeof v === "string"
    ? v
    : typeof (v as Obj)?.text === "string"
      ? ((v as Obj).text as string)
      : "";

/** One Eventbrite event as the collector's ingest item (facts, an excerpt, a link out; no image). */
export function eventItem(e: Obj): Obj | null {
  const id = typeof e.id === "string" ? e.id : null;
  const start = (e.start as Obj | undefined)?.utc;
  const end = (e.end as Obj | undefined)?.utc;
  const url = typeof e.url === "string" && e.url.startsWith("https://") ? e.url : null;
  if (!id || typeof start !== "string" || !url) return null;
  const venue = (e.venue ?? {}) as Obj;
  const address = (venue.address ?? {}) as Obj;
  const lat = Number(venue.latitude ?? address.latitude);
  const lng = Number(venue.longitude ?? address.longitude);
  const online = e.online_event === true;
  const location = online
    ? "Online"
    : [
        text(venue.name),
        typeof address.localized_address_display === "string"
          ? address.localized_address_display
          : "",
      ]
        .filter(Boolean)
        .join(", ")
        .slice(0, 200);
  return {
    external_id: `eb-${id}`,
    title: text(e.name).slice(0, 200),
    description: (text(e.summary) || text(e.description)).slice(0, 300),
    starts_at: start,
    ...(typeof end === "string" ? { ends_at: end } : {}),
    url,
    location,
    ...(Number.isFinite(lat) && Number.isFinite(lng) && !online ? { lat, lng } : {}),
    is_free: e.is_free === true,
    cancelled: e.status === "canceled",
    categories: [],
  };
}

/** The collector job's sync: every connected account's live events into its source. */
export async function sync(deps: {
  keys: Keys | null;
  rpc: Rpc;
  fetch: FetchLike;
  sleep?: (ms: number) => Promise<void>;
  runId: string;
}): Promise<Answer> {
  if (!deps.keys) return SKIPPED;
  const sleep = deps.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  const sources = (await deps.rpc("organizer_eventbrite_sources", { p_limit: 20 })) as Obj[];
  const counts: Record<string, number> = { sources: 0, events: 0, failed: 0 };
  let first = true;
  const get = async (url: string, token: string): Promise<Obj | null> => {
    if (!first) await sleep(SPACING_MS);
    first = false;
    const res = await deps.fetch(url, {
      headers: { Authorization: `Bearer ${token}`, accept: "application/json" },
    });
    if (!res.ok) {
      await res.body?.cancel();
      return null;
    }
    try {
      return (await res.json()) as Obj;
    } catch {
      return null;
    }
  };
  for (const s of Array.isArray(sources) ? sources : []) {
    const token = typeof s.token === "string" ? s.token : "";
    if (!token) continue;
    counts.sources++;
    let complete = true;
    const items: Obj[] = [];
    const orgs = await get(`${API}/users/me/organizations/`, token);
    if (!orgs) {
      complete = false;
      counts.failed++;
    }
    for (const org of (Array.isArray(orgs?.organizations)
      ? (orgs!.organizations as Obj[])
      : []
    ).slice(0, 5)) {
      if (typeof org.id !== "string" || !/^[0-9]{1,20}$/.test(org.id)) continue;
      let continuation: string | null = null;
      for (let page = 0; page < MAX_PAGES; page++) {
        const u = new URL(`${API}/organizations/${org.id}/events/`);
        u.searchParams.set("status", "live");
        u.searchParams.set("expand", "venue");
        if (continuation) u.searchParams.set("continuation", continuation);
        const body = await get(u.toString(), token);
        if (!body) {
          complete = false;
          break;
        }
        for (const e of Array.isArray(body.events) ? (body.events as Obj[]) : []) {
          const it = eventItem(e);
          if (it) items.push(it);
        }
        const pg = (body.pagination ?? {}) as Obj;
        continuation =
          pg.has_more_items === true && typeof pg.continuation === "string"
            ? pg.continuation
            : null;
        if (!continuation) break;
        if (page === MAX_PAGES - 1) complete = false;
      }
    }
    const region = (s.region ?? {}) as Obj;
    await deps.rpc("collector_ingest_events", {
      p_source: {
        slug: s.slug,
        kind: "eventbrite",
        url: `${API}/users/me/organizations/`,
        name: "Eventbrite events",
        attribution: "Listed by the organizer from their Eventbrite account.",
        lane: "api",
        enabled: true,
        ...(typeof region.lat === "number" && typeof region.lng === "number" ? { region } : {}),
      },
      p_items: items.slice(0, 2000),
      p_complete: complete,
      p_enable: false,
      p_run_id: deps.runId,
      p_seen: null,
    });
    counts.events += items.length;
  }
  return { status: 200, body: counts };
}
