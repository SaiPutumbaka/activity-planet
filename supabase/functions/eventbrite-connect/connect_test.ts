// deno test supabase/functions/eventbrite-connect (no network, no keys)
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { eventItem, handleUser, keysFrom, sha256Hex, sync } from "./connect.ts";

const KEYS = {
  clientId: "cid",
  clientSecret: "csecret",
  redirectUri: "https://app.example.org/organizer/eventbrite",
};
const USER = "0b9e7c1a-1111-4222-8333-944445555666";

function fakeRpc(answers: Record<string, (a: Record<string, unknown>) => unknown>) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  return {
    calls,
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      return Promise.resolve(answers[name]?.(args) ?? null);
    },
  };
}
const noFetch = () => Promise.reject(new Error("no network in tests"));

Deno.test("no key: every op is skipped and nothing is called", async () => {
  assertEquals(
    keysFrom(() => undefined),
    null,
  );
  assertEquals(
    keysFrom((n) => (n === "EVENTBRITE_CLIENT_ID" ? "x" : undefined)),
    null,
  );
  const r = fakeRpc({});
  assertEquals(
    await handleUser(USER, { op: "start" }, { keys: null, rpc: r.rpc, fetch: noFetch }),
    {
      status: 200,
      body: { skipped: "no key" },
    },
  );
  assertEquals(
    (await handleUser(USER, { op: "status" }, { keys: null, rpc: r.rpc, fetch: noFetch })).body,
    { available: false },
  );
  assertEquals(await sync({ keys: null, rpc: r.rpc, fetch: noFetch, runId: "t" }), {
    status: 200,
    body: { skipped: "no key" },
  });
  assertEquals(r.calls, []);
});

Deno.test("start stores only the state's hash and returns the authorize URL", async () => {
  const r = fakeRpc({ organizer_oauth_start: () => ({ expires_in: 600 }) });
  const state = "a".repeat(64);
  const out = await handleUser(
    USER,
    { op: "start" },
    { keys: KEYS, rpc: r.rpc, fetch: noFetch, state: () => state },
  );
  const u = new URL(String(out.body.url));
  assertEquals(u.origin + u.pathname, "https://www.eventbrite.com/oauth/authorize");
  assertEquals(u.searchParams.get("state"), state);
  assertEquals(r.calls[0]!.args, { p_user: USER, p_state_hash: await sha256Hex(state) });
});

Deno.test(
  "callback: another person's, a used or an expired state is refused; a good one stores the token",
  async () => {
    const state = "b".repeat(64);
    const hash = await sha256Hex(state);
    let used = false;
    const r = fakeRpc({
      // The database takes the state once, for its own person only.
      organizer_oauth_take: (a) => {
        if (a.p_user !== USER || a.p_state_hash !== hash || used) return false;
        used = true;
        return true;
      },
      organizer_eventbrite_store: () => ({ source_id: "s1", created: true }),
    });
    const exchanges: string[] = [];
    const fetchOk = (url: string, init: RequestInit) => {
      exchanges.push(url);
      assert(String(init.body).includes("grant_type=authorization_code"));
      return Promise.resolve(new Response(JSON.stringify({ access_token: "TOKEN123" })));
    };
    const other = "1c9e7c1a-1111-4222-8333-944445555666";
    assertEquals(
      (
        await handleUser(
          other,
          { op: "callback", code: "abcd", state },
          { keys: KEYS, rpc: r.rpc, fetch: fetchOk },
        )
      ).status,
      403,
    );
    assertEquals(exchanges, []);
    const ok = await handleUser(
      USER,
      { op: "callback", code: "abcd", state },
      { keys: KEYS, rpc: r.rpc, fetch: fetchOk },
    );
    assertEquals(ok, { status: 200, body: { connected: true, source_id: "s1" } });
    assertEquals(exchanges, ["https://www.eventbrite.com/oauth/token"]);
    // Single use.
    assertEquals(
      (
        await handleUser(
          USER,
          { op: "callback", code: "abcd", state },
          { keys: KEYS, rpc: r.rpc, fetch: fetchOk },
        )
      ).status,
      403,
    );
    assertEquals(r.calls.filter((c) => c.name === "organizer_eventbrite_store").length, 1);
  },
);

Deno.test("events map to items without images; sync reads only the API, spaced 2 s", async () => {
  const item = eventItem({
    id: "123",
    name: { text: "Board game night" },
    summary: "Bring a friend",
    start: { utc: "2026-12-01T00:00:00Z" },
    end: { utc: "2026-12-01T02:00:00Z" },
    url: "https://www.eventbrite.com/e/123",
    logo: { url: "https://img.evbuc.com/x.jpg" },
    is_free: true,
    venue: {
      name: "Hall",
      latitude: "33.7",
      longitude: "-84.4",
      address: { localized_address_display: "1 Main St" },
    },
  })!;
  assertEquals(item.external_id, "eb-123");
  assertEquals(item.location, "Hall, 1 Main St");
  assertEquals("cover_url" in item, false);
  const urls: string[] = [];
  const slept: number[] = [];
  const r = fakeRpc({
    organizer_eventbrite_sources: () => [
      {
        source_id: "s1",
        slug: "org-0123456789ab",
        token: "T",
        region: { lat: 33.7, lng: -84.4, radius_km: 25 },
      },
    ],
    collector_ingest_events: () => ({ inserted: 1 }),
  });
  const out = await sync({
    keys: KEYS,
    rpc: r.rpc,
    runId: "t1",
    sleep: (ms) => {
      slept.push(ms);
      return Promise.resolve();
    },
    fetch: (url) => {
      urls.push(url);
      const body = url.includes("/users/me/organizations/")
        ? { organizations: [{ id: "77" }] }
        : {
            events: [
              {
                id: "123",
                name: { text: "X" },
                start: { utc: "2026-12-01T00:00:00Z" },
                url: "https://www.eventbrite.com/e/123",
              },
            ],
            pagination: { has_more_items: false },
          };
      return Promise.resolve(new Response(JSON.stringify(body)));
    },
  });
  assertEquals(out.body, { sources: 1, events: 1, failed: 0 });
  assert(urls.every((u) => u.startsWith("https://www.eventbriteapi.com/v3/")));
  assertEquals(slept, [2000]);
  const ingest = r.calls.find((c) => c.name === "collector_ingest_events")!;
  assertEquals((ingest.args.p_source as Record<string, unknown>).kind, "eventbrite");
  assertEquals(ingest.args.p_complete, true);
});
