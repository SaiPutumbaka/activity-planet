// deno test --allow-read supabase/functions/places-fill
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import {
  categoryGroups,
  CREDITS_PER_PAGE,
  featureRow,
  MAX_REQUESTS_PER_TILE,
  type Plan,
  placesUrl,
  type Rule,
  Rules,
  runFill,
  runId,
  tileId,
} from "./fill.ts";

// The real rules the nightly extract uses (scripts/places/extract_rules.json, same shape as
// public.place_rules through places_fill_plan).
const doc = JSON.parse(
  await Deno.readTextFile(new URL("../../../scripts/places/extract_rules.json", import.meta.url)),
) as { kinds: string[]; rules: Rule[] };
const rules = new Rules(doc.rules, doc.kinds);

// Freiburg im Breisgau, tile 198375.
const FREIBURG = 198375;
const BBOX: [number, number, number, number] = [7.5, 47.5, 8, 48];

function feature(over: Record<string, unknown> = {}, raw: Record<string, unknown> = {}) {
  return {
    type: "Feature",
    properties: {
      name: "Basketballplatz Seepark",
      place_id: "51abc0001",
      lat: 47.9991,
      lon: 7.8245,
      street: "Seeparkweg",
      housenumber: "3",
      city: "Freiburg im Breisgau",
      country_code: "de",
      datasource: {
        sourcename: "openstreetmap",
        raw: { osm_type: "w", osm_id: 123456, leisure: "pitch", sport: "basketball", ...raw },
      },
      ...over,
    },
    geometry: { type: "Point", coordinates: [7.8245, 47.9991] },
  };
}

Deno.test("tile arithmetic matches public.place_tile_id", () => {
  assertEquals(tileId(47.9991, 7.8245), FREIBURG);
  assertEquals(tileId(33.749, -84.388), 178031);
});

Deno.test("category groups: broad ones dropped, round-robin order, most used first", () => {
  const groups = categoryGroups([
    ["sport.fitness", 51],
    ["sport.pitch", 43],
    ["ski", 20],
    ["sport", 19],
    ["catering.bar", 15],
    ["commercial", 7],
    ["building", 1],
    ["education.library", 7],
    ["activity.sport_club", 10],
    ["Bad Category", 3],
    ["unknown.thing", 3],
  ]);
  assertEquals(groups, [
    ["sport.fitness", "sport.pitch"],
    ["activity.sport_club"],
    ["ski"],
    ["education.library"],
    ["catering.bar"],
  ]);
});

Deno.test("places url: categories, rect filter, page, key", () => {
  const u = new URL(placesUrl(["sport.pitch", "ski"], BBOX, 100, "k"));
  assertEquals(u.origin + u.pathname, "https://api.geoapify.com/v2/places");
  assertEquals(u.searchParams.get("categories"), "sport.pitch,ski");
  assertEquals(u.searchParams.get("filter"), "rect:7.5,47.5,8,48");
  assertEquals(u.searchParams.get("limit"), "100");
  assertEquals(u.searchParams.get("offset"), "100");
  assertEquals(u.searchParams.get("apiKey"), "k");
  assertEquals(CREDITS_PER_PAGE, 5);
});

Deno.test("feature row: same kind and rules as the OSM extract, osm_ref for the merge", () => {
  const out = featureRow(feature(), FREIBURG, rules);
  assert("row" in out);
  const row = out.row;
  assertEquals(row.source_id, "51abc0001");
  assertEquals(row.osm_ref, "w123456");
  assertEquals(row.name, "Basketballplatz Seepark");
  assertEquals(row.kind, "court_field");
  const expected = rules.match({ leisure: "pitch", sport: "basketball" }, "w").map((r) => r.id);
  assertEquals(
    row.rule_ids,
    [...new Set(expected)].sort((a, b) => a - b),
  );
  assert(row.rule_ids.length > 0);
  assertEquals(row.address_text, "3 Seeparkweg");
  assertEquals(row.locality, "Freiburg im Breisgau");
  assertEquals(row.country, "DE");
  assertEquals(row.tags, { sport: "basketball" });
});

Deno.test("feature row: drops what the OSM extract drops, and anything outside the tile", () => {
  const drop = (f: unknown) => {
    const out = featureRow(f, FREIBURG, rules);
    return "drop" in out ? out.drop : "kept";
  };
  assertEquals(drop(feature({ name: "" }, { name: "" })), "unnamed");
  assertEquals(drop(feature({}, { access: "private" })), "access_private");
  assertEquals(drop(feature({}, { leisure: "x_unknown", sport: "none" })), "no_rules");
  assertEquals(drop(feature({ lat: 48.2, lon: 7.8 })), "outside_tile");
  assertEquals(drop(feature({ lat: "48" })), "no_point");
  assertEquals(drop(feature({ place_id: "" })), "no_place_id");
  assertEquals(
    drop({ properties: { place_id: "x", name: "n", lat: 47.9, lon: 7.8, datasource: {} } }),
    "no_osm_tags",
  );
  assertEquals(drop(null), "not_feature");
  // Phone only for named businesses, as in the extract.
  const cafe = featureRow(
    feature(
      { name: "Café Pow" },
      { leisure: undefined, sport: undefined, amenity: "cafe", phone: "+49 1" },
    ),
    FREIBURG,
    rules,
  );
  assert("row" in cafe);
  assertEquals(cafe.row.tags?.phone, "+49 1");
});

Deno.test("run id fits the collector run id format", () => {
  const id = runId(new Date("2026-11-04T10:15:30Z"), FREIBURG);
  assertEquals(id, "geoapify-202611041015-198375");
  assert(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/.test(id));
});

// ---------------------------------------------------------------------------------------------
// runFill with fake I/O

function plan(over: Partial<Plan> = {}): Plan {
  return {
    tiles: [{ id: FREIBURG, bbox: BBOX }],
    budget: { day: "2026-11-04", cap: 500, used: 0, left: 500 },
    categories: [
      ["sport.pitch", 43],
      ["catering.cafe", 8],
    ],
    kinds: doc.kinds,
    rules: doc.rules,
    ...over,
  };
}

function fakeDb(p: Plan, budget = 500) {
  const calls: [string, Record<string, unknown>][] = [];
  let left = budget;
  const rpc = (name: string, args: Record<string, unknown>) => {
    calls.push([name, args]);
    if (name === "places_fill_plan") return Promise.resolve(p);
    if (name === "places_fill_spend") {
      const c = args.p_credits as number;
      if (left - c < 0) return Promise.resolve(null);
      left -= c;
      return Promise.resolve(left);
    }
    if (name === "ingest_places")
      return Promise.resolve({
        inserted: (args.p_batch as unknown[]).length,
        updated: 0,
        skipped: {},
      });
    if (name === "finish_place_tile") return Promise.resolve({ row_count: args.p_count });
    if (name === "places_fill_release") return Promise.resolve(true);
    return Promise.reject(new Error(`unexpected ${name}`));
  };
  return { rpc, calls };
}

const quiet = () => {};
const noSleep = () => Promise.resolve();

Deno.test("no key: skipped cleanly, nothing called", async () => {
  const db = fakeDb(plan());
  let fetched = 0;
  const logs: unknown[][] = [];
  for (const key of [undefined, null, "", "   "]) {
    const r = await runFill({
      key,
      rpc: db.rpc,
      fetch: () => {
        fetched++;
        return Promise.resolve(new Response("{}"));
      },
      log: (...a) => logs.push(a),
    });
    assertEquals(r, { skipped: "no_key", tiles: [], budget_left: null });
  }
  assertEquals(db.calls.length, 0);
  assertEquals(fetched, 0);
  assertEquals(logs[0], ["places-fill skipped: no key"]);
});

Deno.test("fill: pages per group, spends before each request, ingests as geoapify", async () => {
  const db = fakeDb(plan());
  const urls: string[] = [];
  const r = await runFill({
    key: "secret-key",
    rpc: db.rpc,
    fetch: (url) => {
      urls.push(url);
      const u = new URL(url);
      const cats = u.searchParams.get("categories");
      const offset = Number(u.searchParams.get("offset") ?? "0");
      // sport.pitch: a full first page (100 courts, 2 duplicates of one element), then 3 more.
      let features: unknown[] = [];
      if (cats === "sport.pitch" && offset === 0) {
        features = Array.from({ length: 100 }, (_, i) =>
          feature(
            { place_id: `p${i}`, name: `Court ${i}`, lat: 47.9 + i * 0.0001 },
            { osm_id: i < 2 ? 777 : 1000 + i },
          ),
        );
      } else if (cats === "sport.pitch" && offset === 100) {
        features = [1, 2, 3].map((i) =>
          feature({ place_id: `q${i}`, name: `Field ${i}` }, { osm_id: 5000 + i }),
        );
      } else if (cats === "catering.cafe") {
        features = [
          feature(
            { place_id: "c1", name: "Café" },
            { leisure: undefined, sport: undefined, amenity: "cafe", osm_id: 9 },
          ),
        ];
      }
      return Promise.resolve(new Response(JSON.stringify({ type: "FeatureCollection", features })));
    },
    sleep: noSleep,
    log: quiet,
    now: () => new Date("2026-11-04T10:15:00Z"),
  });

  // Round robin: sport page 1, food page 1, then sport page 2 (only sport returned a full page).
  assertEquals(
    urls.map((u) => [
      new URL(u).searchParams.get("categories"),
      new URL(u).searchParams.get("offset"),
    ]),
    [
      ["sport.pitch", null],
      ["catering.cafe", null],
      ["sport.pitch", "100"],
    ],
  );
  const spends = db.calls.filter(([n]) => n === "places_fill_spend");
  assertEquals(spends.length, 3);
  const t = r.tiles[0];
  assertEquals(t.outcome, "filled");
  assertEquals(t.requests, 3);
  assertEquals(t.credits, 15);
  assertEquals(t.features, 104);
  assertEquals(t.dropped, { duplicate: 1 });
  const ingest = db.calls.find(([n]) => n === "ingest_places")![1];
  assertEquals(ingest.p_source, "geoapify");
  assertEquals(ingest.p_run_id, "geoapify-202611041015-198375");
  assertEquals((ingest.p_batch as unknown[]).length, 103);
  const finish = db.calls.find(([n]) => n === "finish_place_tile")![1];
  assertEquals(finish, {
    p_tile_id: FREIBURG,
    p_run_id: "geoapify-202611041015-198375",
    p_count: 103,
    p_source: "geoapify",
  });
  assertEquals(r.budget_left, 485);
  assertEquals(r.stopped, undefined);
});

Deno.test("fill: at most 8 requests a tile", async () => {
  const db = fakeDb(plan({ categories: [["sport.pitch", 1]] }));
  let n = 0;
  const r = await runFill({
    key: "k",
    rpc: db.rpc,
    fetch: () => {
      n++;
      const features = Array.from({ length: 100 }, (_, i) =>
        feature({ place_id: `p${n}-${i}`, name: `Court ${n}-${i}` }, { osm_id: n * 1000 + i }),
      );
      return Promise.resolve(new Response(JSON.stringify({ features })));
    },
    sleep: noSleep,
    log: quiet,
  });
  assertEquals(n, MAX_REQUESTS_PER_TILE);
  assertEquals(r.tiles[0].rows, 800);
});

Deno.test("budget refused before the first request: tile released, nothing ingested", async () => {
  const db = fakeDb(
    plan({
      tiles: [
        { id: FREIBURG, bbox: BBOX },
        { id: 178031, bbox: [-84.5, 33.5, -84, 34] },
      ],
    }),
    3,
  );
  let fetched = 0;
  const r = await runFill({
    key: "k",
    rpc: db.rpc,
    fetch: () => {
      fetched++;
      return Promise.resolve(new Response("{}"));
    },
    sleep: noSleep,
    log: quiet,
  });
  assertEquals(fetched, 0);
  assertEquals(r.stopped, "budget");
  assertEquals(
    r.tiles.map((t) => [t.tile_id, t.outcome, t.reason]),
    [
      [FREIBURG, "released", "budget"],
      [178031, "released", "budget"],
    ],
  );
  assertEquals(db.calls.filter(([n]) => n === "places_fill_release").length, 2);
  assertEquals(db.calls.filter(([n]) => n === "ingest_places").length, 0);
});

Deno.test("a refused key stops the run; the key is never in the result", async () => {
  const db = fakeDb(
    plan({
      tiles: [
        { id: FREIBURG, bbox: BBOX },
        { id: 178031, bbox: [-84.5, 33.5, -84, 34] },
      ],
    }),
  );
  const r = await runFill({
    key: "very-secret-key",
    rpc: db.rpc,
    fetch: () => Promise.resolve(new Response("bad key", { status: 401 })),
    sleep: noSleep,
    log: quiet,
  });
  assertEquals(r.stopped, "geoapify_http_401");
  assertEquals(
    r.tiles.map((t) => t.outcome),
    ["released", "released"],
  );
  assert(!JSON.stringify(r).includes("very-secret-key"));
  assertEquals(db.calls.filter(([n]) => n === "ingest_places").length, 0);
});

Deno.test("no tile to fill: one plan call, no requests", async () => {
  const db = fakeDb(plan({ tiles: [] }));
  const r = await runFill({
    key: "k",
    rpc: db.rpc,
    fetch: () => Promise.reject(new Error("no")),
    log: quiet,
  });
  assertEquals(r, { tiles: [], budget_left: 500 });
  assertEquals(
    db.calls.map(([n]) => n),
    ["places_fill_plan"],
  );
});

Deno.test(
  "a 400 on one group skips that group only; the tile's other groups are still read",
  async () => {
    const db = fakeDb(
      plan({
        categories: [
          ["sport.pitch", 43],
          ["activity.club", 3],
          ["catering.cafe", 8],
        ],
      }),
    );
    const asked: (string | null)[] = [];
    const r = await runFill({
      key: "k",
      rpc: db.rpc,
      fetch: (url) => {
        const cats = new URL(url).searchParams.get("categories");
        asked.push(cats);
        if (cats === "activity.club") return Promise.resolve(new Response("bad", { status: 400 }));
        const id = cats === "sport.pitch" ? 1 : 2;
        return Promise.resolve(
          new Response(
            JSON.stringify({
              features: [
                feature(
                  { place_id: `x${id}`, name: `Spot ${id}` },
                  cats === "catering.cafe"
                    ? { leisure: undefined, sport: undefined, amenity: "cafe", osm_id: 70 + id }
                    : { osm_id: 70 + id },
                ),
              ],
            }),
          ),
        );
      },
      sleep: noSleep,
      log: quiet,
    });
    assertEquals(asked, ["sport.pitch", "activity.club", "catering.cafe"]);
    assertEquals(r.stopped, undefined);
    const t = r.tiles[0]!;
    assertEquals(t.outcome, "filled");
    assertEquals(t.reason, "geoapify_http_400");
    assertEquals(t.dropped.refused_group, 1);
    assertEquals(t.requests, 3);
    assertEquals(t.rows, 2);
  },
);

Deno.test("only 400s: nothing answered, the tile is released", async () => {
  const db = fakeDb(plan());
  const r = await runFill({
    key: "k",
    rpc: db.rpc,
    fetch: () => Promise.resolve(new Response("bad", { status: 400 })),
    sleep: noSleep,
    log: quiet,
  });
  assertEquals(r.tiles[0]!.outcome, "released");
  assertEquals(db.calls.filter(([n]) => n === "ingest_places").length, 0);
});
