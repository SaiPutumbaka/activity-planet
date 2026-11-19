import { assert, assertEquals } from "jsr:@std/assert@1";
import { cacheKey, type Deps, geoapifyUrl, handle, parseRequest, pickResults } from "./search.ts";

function deps(over: Partial<Deps> = {}): Deps & { fetched: URL[]; stored: string[] } {
  const fetched: URL[] = [];
  const stored: string[] = [];
  return {
    apiKey: "server-key",
    userId: (t) => Promise.resolve(t === "good" ? "user-1" : null),
    take: () => Promise.resolve({ allowed: true }),
    store: (k) => {
      stored.push(k);
      return Promise.resolve();
    },
    fetch: (u) => {
      fetched.push(u);
      return Promise.resolve(
        new Response(
          JSON.stringify({
            results: [
              {
                formatted: "25 Park Place, Atlanta",
                address_line1: "25 Park Place",
                housenumber: "25",
                result_type: "building",
                city: "Atlanta",
                lat: 33.75,
                lon: -84.38,
                place_id: "p1",
                datasource: { raw: { secret: "x" } },
                timezone: { name: "America/New_York" },
              },
              { formatted: "no point", place_id: "p2" },
            ],
          }),
        ),
      );
    },
    ...over,
    fetched,
    stored,
  };
}

Deno.test("parseRequest checks kind, text, bias and language", () => {
  assertEquals(parseRequest(null), { error: "invalid_body" });
  assertEquals(parseRequest({ kind: "x", text: "Lisbon" }), { error: "invalid_kind" });
  assertEquals(parseRequest({ kind: "address", text: "abc" }), { error: "invalid_text" });
  assertEquals(parseRequest({ kind: "city", text: "x".repeat(121) }), { error: "invalid_text" });
  assertEquals(parseRequest({ kind: "address", text: "25 park", bias: { lat: 99, lng: 0 } }), {
    error: "invalid_bias",
  });
  assertEquals(
    parseRequest({
      kind: "address",
      text: "  25   park pl ",
      bias: { lat: 33.7512, lng: -84.3888 },
      lang: "en",
    }),
    { kind: "address", text: "25 park pl", bias: { lat: 33.75, lng: -84.39 }, lang: "en" },
  );
  // A city search is never biased, and a bad language is dropped.
  assertEquals(
    parseRequest({ kind: "city", text: "Lis", bias: { lat: 1, lng: 1 }, lang: "EN-us" }),
    {
      kind: "city",
      text: "Lis",
      bias: null,
      lang: null,
    },
  );
});

Deno.test("cacheKey ignores case and spacing but not kind", async () => {
  const a = await cacheKey({ kind: "city", text: "Lisbon", bias: null, lang: null });
  const b = await cacheKey({ kind: "city", text: "lisbon", bias: null, lang: null });
  const c = await cacheKey({ kind: "address", text: "lisbon", bias: null, lang: null });
  assert(/^[0-9a-f]{64}$/.test(a));
  assertEquals(a, b);
  assert(a !== c);
});

Deno.test("geoapifyUrl sets the limit per kind and the bias", () => {
  const u = geoapifyUrl(
    { kind: "address", text: "25 park", bias: { lat: 1.5, lng: 2.5 }, lang: null },
    "k",
  );
  assertEquals(u.searchParams.get("limit"), "5");
  assertEquals(u.searchParams.get("bias"), "proximity:2.5,1.5");
  assertEquals(u.searchParams.get("apiKey"), "k");
  assertEquals(
    geoapifyUrl({ kind: "city", text: "Lis", bias: null, lang: "pt" }, "k").searchParams.get(
      "limit",
    ),
    "10",
  );
});

Deno.test("pickResults keeps only the fields the app reads", () => {
  const out = pickResults({
    results: [
      { name: "Park", lat: 1, lon: 2, place_id: "a", datasource: {}, rank: { x: 1 } },
      { lat: 1 },
    ],
  });
  assertEquals(out, [{ name: "Park", lat: 1, lon: 2, place_id: "a" }]);
  assertEquals(pickResults({}), []);
});

Deno.test("handle: token, key and caps", async () => {
  assertEquals((await handle(null, {}, deps())).status, 401);
  assertEquals((await handle("bad", {}, deps())).status, 401);
  const off = deps({ apiKey: null });
  assertEquals(await handle("good", { kind: "city", text: "Lisbon" }, off), {
    status: 200,
    body: { enabled: false, results: [] },
  });
  assertEquals(off.fetched.length, 0);
  assertEquals((await handle("good", { kind: "city", text: "x" }, deps())).status, 400);
  const limited = await handle(
    "good",
    { kind: "city", text: "Lisbon" },
    deps({ take: () => Promise.resolve({ allowed: false, limit: "global" }) }),
  );
  assertEquals(limited, { status: 429, body: { error: "too_many_searches", limit: "global" } });
  const gone = await handle(
    "good",
    { kind: "city", text: "Lisbon" },
    deps({ take: () => Promise.resolve({ allowed: false, limit: "user_not_found" }) }),
  );
  assertEquals(gone.status, 403);
});

Deno.test(
  "handle: a cached answer skips Geoapify; a miss is fetched, trimmed and stored",
  async () => {
    const cached = deps({
      take: () => Promise.resolve({ allowed: true, cached: [{ place_id: "c" }] }),
    });
    const a = await handle("good", { kind: "city", text: "Lisbon" }, cached);
    assertEquals(a.body, { enabled: true, results: [{ place_id: "c" }], cached: true });
    assertEquals(cached.fetched.length, 0);

    const miss = deps();
    const b = await handle("good", { kind: "address", text: "25 park pl" }, miss);
    assertEquals(b.status, 200);
    assertEquals(miss.fetched.length, 1);
    assertEquals(miss.stored.length, 1);
    const results = b.body.results as Record<string, unknown>[];
    assertEquals(results.length, 1);
    assertEquals(Object.keys(results[0]).sort(), [
      "address_line1",
      "city",
      "formatted",
      "housenumber",
      "lat",
      "lon",
      "place_id",
      "result_type",
    ]);

    const down = deps({ fetch: () => Promise.resolve(new Response("no", { status: 500 })) });
    assertEquals((await handle("good", { kind: "city", text: "Lisbon" }, down)).status, 502);
    assertEquals(down.stored.length, 0);
  },
);
