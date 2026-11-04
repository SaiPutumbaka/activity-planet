import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { afterEach, describe, expect, it } from "vitest";

import {
  decodeMapInView,
  loadMapView,
  resetPlaceFilesBackoff,
  type MapAdapter,
  type MapInViewArgs,
  type MapQueryParams,
} from "../map";
import {
  decodePlaceFiles,
  decodeRulesFile,
  decodeTileFile,
  filePlaceDetail,
  fetchLoader,
  osmRefOfPlaceId,
  placesBaseUrl,
  readJsonBody,
  resetFilePlaces,
  type PlaceFileLoader,
} from "../place-files";

/**
 * Static place files (D-042 slice 5) against real staging data: for Downtown Atlanta (tile
 * 178031) and the Freiburg Altstadt (tile 198375), the files path (map_in_view with p_files, the
 * tile file and the rules file merged on the client) must give exactly the places, hubs, flags
 * and order that map_in_view gave from Postgres for the same bbox (fixtures/place-files/*.json,
 * read-only SELECTs on staging, 2026-11-04).
 */

type Case = "all" | "sel" | "gen";
interface Fixture {
  bbox: [number, number, number, number];
  sel: string[];
  gen: string;
  hubs: [string, string, string, string, "specific" | "generic", number[]][];
  resp: Record<Case, { hubs: unknown[][]; generic: boolean }>;
  tiles: Record<string, unknown[][]>;
  expect: Partial<Record<Case, { places: [string, string[], number][]; truncated: boolean }>>;
}

function fixture(name: string): Fixture {
  return JSON.parse(
    readFileSync(new URL(`./fixtures/place-files/${name}.json`, import.meta.url), "utf8"),
  ) as Fixture;
}

const COLS = [
  "osm_ref",
  "lng",
  "lat",
  "kind",
  "name",
  "rule_ids",
  "address",
  "locality",
  "hours",
  "website",
  "tags",
];
const RULES_PATH = "rules/v1.00000000000000aa.json.gz";
const tilePath = (t: string) => `places/v1/${t}.00000000000000bb.json.gz`;

/** The files as build_place_files.py writes them (format v1), gzipped, behind a loader. */
function filesFor(fx: Fixture, calls: string[] = []): PlaceFileLoader {
  const bodies = new Map<string, Uint8Array>();
  bodies.set(
    RULES_PATH,
    gzipSync(
      JSON.stringify({
        v: 1,
        rules_version: 1,
        cols: ["id", "slug", "name", "emoji", "mode", "rules"],
        hubs: fx.hubs,
      }),
    ),
  );
  for (const [t, rows] of Object.entries(fx.tiles)) {
    bodies.set(
      tilePath(t),
      gzipSync(
        JSON.stringify({
          v: 1,
          tile: Number(t),
          rules_version: 1,
          license: "ODbL-1.0",
          attribution: "© OpenStreetMap contributors",
          cols: COLS,
          rows,
        }),
      ),
    );
  }
  return {
    async load(path) {
      calls.push(path);
      const b = bodies.get(path);
      if (!b) throw new Error(`no file ${path}`);
      return readJsonBody(b);
    },
  };
}

/**
 * map_in_view as built (migration 42): with p_files every OSM row of the tile comes from the file
 * (staging has no corrected rows there), so places is empty and place_files names the files.
 */
function adapterFor(fx: Fixture, which: Case, calls: MapInViewArgs[] = []): MapAdapter {
  return {
    async mapInView(args) {
      calls.push(args);
      const r = fx.resp[which];
      return {
        v: 1,
        places: [],
        plans: [],
        shows: [],
        cells: [],
        hubs: r.hubs,
        generic: r.generic,
        mapping: false,
        place_files: args.p_files
          ? {
              rules: RULES_PATH,
              rules_version: 1,
              tiles: Object.entries(fx.tiles).map(([t, rows]) => [
                Number(t),
                tilePath(t),
                rows.length,
              ]),
              hidden: [],
              sel: r.hubs.length,
              all: which === "all",
            }
          : null,
      };
    },
    async placesInView() {
      return null;
    },
    async placeDetail() {
      return null;
    },
  };
}

function params(fx: Fixture, which: Case): MapQueryParams {
  const [west, south, east, north] = fx.bbox;
  return {
    bbox: { west, south, east, north },
    hubIds: which === "all" ? null : which === "sel" ? fx.sel : [fx.gen],
    generic: which === "gen",
    when: "week",
  };
}

const BASE = "https://example.test/activity-planet/";

afterEach(() => {
  resetPlaceFilesBackoff();
  resetFilePlaces();
});

describe.each([
  ["Downtown Atlanta, tile 178031", "atlanta-downtown"],
  ["Freiburg Altstadt, tile 198375", "freiburg-altstadt"],
])("static files match Postgres: %s", (_label, name) => {
  const fx = fixture(name);
  const slug = new Map(fx.hubs.map((h) => [h[0], h[1]]));

  it.each(["all", "sel", "gen"] as Case[])("%s", async (which) => {
    const calls: MapInViewArgs[] = [];
    const view = await loadMapView(adapterFor(fx, which, calls), params(fx, which), {
      filesBase: BASE,
      loader: filesFor(fx),
    });
    expect(calls).toHaveLength(1);
    expect(calls[0]?.p_files).toBe(true);
    const got = view.places.map((p) => [p.osmRef, p.hubIds.map((h) => slug.get(h) ?? h), p.flags]);
    const want = fx.expect[which]?.places ?? [];
    expect(want.length).toBeGreaterThan(0);
    // Same places, hubs and flags. The order is the server's (nearest the centre) up to ties: the
    // files keep 5 decimals, so two places a metre apart can swap.
    const byRef = (x: unknown[], y: unknown[]) => String(x[0]).localeCompare(String(y[0]));
    expect([...got].sort(byRef)).toEqual([...want].sort(byRef));
    // At every position the two answers are the same distance from the centre, within 2 m.
    const at = new Map(
      Object.values(fx.tiles)
        .flat()
        .map((r) => [r[0] as string, r]),
    );
    const [w, so, e, n] = fx.bbox;
    const dist = (ref: unknown) => {
      const r = at.get(ref as string) as number[];
      return Math.hypot((r[1] as number) - (w + e) / 2, (r[2] as number) - (so + n) / 2);
    };
    const off = got.filter((g, i) => Math.abs(dist(g[0]) - dist(want[i]?.[0])) > 2e-5);
    expect(off).toEqual([]);
    expect(view.truncated).toBe(fx.expect[which]?.truncated ?? false);
    // Every file place has its card from the file and the "o:" id the sheet opens.
    for (const p of view.places) {
      expect(osmRefOfPlaceId(p.id)).toBe(p.osmRef);
      expect(p.kind).toBe("place");
    }
  });

  it("rows outside the bbox stay out, and the card reads the file", async () => {
    const view = await loadMapView(adapterFor(fx, "all"), params(fx, "all"), {
      filesBase: BASE,
      loader: filesFor(fx),
    });
    const [w, s, e, n] = fx.bbox;
    expect(view.places.every((p) => p.lng >= w && p.lng <= e && p.lat >= s && p.lat <= n)).toBe(
      true,
    );
    const rows = Object.values(fx.tiles).flat();
    expect(rows.length).toBeGreaterThan(view.places.length);
    const first = view.places[0];
    const d = filePlaceDetail(first?.osmRef as string);
    expect(d?.name).toBe(first?.name);
    expect(d?.source).toBe("osm");
    expect(d?.osmUrl).toMatch(/^https:\/\/www\.openstreetmap\.org\/(node|way|relation)\/\d+$/);
    expect(d?.hubs.length).toBeGreaterThan(0);
  });
});

describe("merge with the database overlay", () => {
  const fx = fixture("atlanta-downtown");
  const p = params(fx, "sel");

  function overlayAdapter(extra: Record<string, unknown>, places: unknown[]): MapAdapter {
    const base = adapterFor(fx, "sel");
    return {
      ...base,
      async mapInView(args) {
        const r = (await base.mapInView(args)) as Record<string, unknown>;
        return {
          ...r,
          places,
          place_files: { ...(r.place_files as object), ...extra },
        };
      },
    };
  }

  it("a database row with the same osm_ref wins, hidden refs go, own pins come first", async () => {
    // [id, lng, lat, kind, hub_idx, flags, name, hub_idxs, osm_ref]
    const corrected = [
      "11111111-1111-4111-8111-111111111111",
      -84.38702,
      33.75221,
      "library",
      0,
      0,
      "Library South (corrected)",
      [0],
      "w252608888",
    ];
    const mine = [
      "22222222-2222-4222-8222-222222222222",
      -84.3915,
      33.7555,
      "spot",
      null,
      2 | 4 | 8 | 64,
      "My pin",
      [],
      null,
    ];
    const view = await loadMapView(
      overlayAdapter({ hidden: ["w252608887"] }, [corrected, mine]),
      p,
      { filesBase: BASE, loader: filesFor(fx) },
    );
    const refs = view.places.map((x) => x.osmRef ?? x.id);
    expect(refs[0]).toBe("22222222-2222-4222-8222-222222222222");
    expect(refs.filter((r) => r === "w252608888")).toHaveLength(1);
    expect(view.places.find((x) => x.osmRef === "w252608888")?.name).toBe(
      "Library South (corrected)",
    );
    expect(refs).not.toContain("w252608887");
    expect(view.places).toHaveLength((fx.expect.sel?.places.length ?? 0) - 1 + 1);
  });

  it("caps at 800 nearest the centre and says truncated", async () => {
    const big: Fixture = JSON.parse(JSON.stringify(fx));
    const tile = Object.keys(big.tiles)[0] as string;
    big.tiles[tile] = Array.from({ length: 900 }, (_, i) => [
      `n${900000000 + i}`,
      -84.3875 + (i % 30) * 0.0001,
      33.753 + Math.floor(i / 30) * 0.0001,
      "park",
      `Park ${i}`,
      [203],
      null,
      null,
      null,
      null,
      null,
    ]);
    const view = await loadMapView(adapterFor(big, "sel"), params(big, "sel"), {
      filesBase: BASE,
      loader: filesFor(big),
    });
    expect(view.places).toHaveLength(800);
    expect(view.truncated).toBe(true);
  });

  it("falls back to Postgres when a file cannot be read, and stops trying for a while", async () => {
    const calls: MapInViewArgs[] = [];
    const adapter = adapterFor(fx, "sel", calls);
    const broken: PlaceFileLoader = {
      load: async () => {
        throw new Error("HTTP 404");
      },
    };
    const view = await loadMapView(adapter, p, { filesBase: BASE, loader: broken });
    expect(calls.map((c) => c.p_files)).toEqual([true, undefined]);
    expect(view.places).toEqual([]);
    await loadMapView(adapter, p, { filesBase: BASE, loader: broken });
    expect(calls.map((c) => c.p_files)).toEqual([true, undefined, undefined]);
  });

  it("never asks for files without a base URL", async () => {
    const calls: MapInViewArgs[] = [];
    await loadMapView(adapterFor(fx, "sel", calls), p, { filesBase: null });
    expect(calls[0]).not.toHaveProperty("p_files");
  });

  it("loads each file once per tile, not per view", async () => {
    const loads: string[] = [];
    const loader = filesFor(fx, loads);
    const cached: PlaceFileLoader = (() => {
      const m = new Map<string, Promise<unknown>>();
      return { load: (path) => m.get(path) ?? (m.set(path, loader.load(path)), m.get(path)!) };
    })();
    await loadMapView(adapterFor(fx, "sel"), p, { filesBase: BASE, loader: cached });
    await loadMapView(adapterFor(fx, "all"), params(fx, "all"), {
      filesBase: BASE,
      loader: cached,
    });
    expect(loads.sort()).toEqual([RULES_PATH, tilePath("178031")].sort());
  });
});

describe("formats and config", () => {
  it("decodes place_files and refuses bad paths", () => {
    const ok = decodePlaceFiles({
      rules: RULES_PATH,
      rules_version: 1,
      tiles: [[178031, tilePath("178031"), 3]],
      hidden: ["n1", "bad"],
      sel: 2,
      all: false,
    });
    expect(ok?.tiles).toEqual([{ id: 178031, path: tilePath("178031"), count: 3 }]);
    expect([...(ok?.hidden ?? [])]).toEqual(["n1"]);
    expect(decodePlaceFiles(null)).toBeNull();
    expect(decodePlaceFiles({ rules: "../x", tiles: [] })).toBeNull();
    expect(decodePlaceFiles({ rules: RULES_PATH, tiles: [[1, tilePath("178031"), 3]] })).toBeNull();
    expect(decodePlaceFiles({ rules: RULES_PATH, tiles: [] })).toBeNull();
  });

  it("reads gzip and plain JSON bodies", async () => {
    expect(await readJsonBody(gzipSync(JSON.stringify({ a: 1 })))).toEqual({ a: 1 });
    expect(await readJsonBody(new TextEncoder().encode('{"b":2}'))).toEqual({ b: 2 });
  });

  it("drops malformed rows and refuses unknown formats", () => {
    const t = decodeTileFile({
      v: 1,
      tile: 5,
      rows: [
        ["n1", 1, 2, "park", "A", [3]],
        ["x1", 1, 2, "park", "B", [3]],
        ["n2", 999, 2, "park", "C", [3]],
        ["n3", 1, 2, "park", "D", []],
      ],
    });
    expect(t.rows.map((r) => r.osmRef)).toEqual(["n1"]);
    expect(() => decodeTileFile({ v: 2, tile: 5, rows: [] })).toThrow();
    const r = decodeRulesFile({
      v: 1,
      hubs: [
        ["h1", "a", "A", "", "specific", [1, 2]],
        ["h2", "b", "B", "", "generic", [3]],
        ["h3", "c", "C", "", "none", [4]],
      ],
    });
    expect([...r.specificRules].sort()).toEqual([1, 2]);
    expect(r.hubs.has("h3")).toBe(false);
  });

  it("takes only an https base URL", () => {
    expect(placesBaseUrl("https://saiputumbaka.github.io/activity-planet")).toBe(
      "https://saiputumbaka.github.io/activity-planet/",
    );
    expect(placesBaseUrl("http://example.com/")).toBeNull();
    expect(placesBaseUrl("")).toBeNull();
    expect(placesBaseUrl(undefined)).toBeNull();
  });

  it("fetchLoader keeps a file after the first fetch and retries after a failure", async () => {
    let n = 0;
    const fake = (async (url: string) => {
      n += 1;
      if (url.endsWith("bad.json.gz")) return new Response("no", { status: 404 });
      return new Response(gzipSync('{"ok":true}'));
    }) as unknown as typeof fetch;
    const l = fetchLoader(BASE, 4, fake);
    expect(await l.load("places/v1/1.json.gz")).toEqual({ ok: true });
    expect(await l.load("places/v1/1.json.gz")).toEqual({ ok: true });
    expect(n).toBe(1);
    await expect(l.load("bad.json.gz")).rejects.toThrow("HTTP 404");
    await expect(l.load("bad.json.gz")).rejects.toThrow();
    expect(n).toBe(3);
  });

  it("decodeMapInView keeps osm_ref from element 8", () => {
    const v = decodeMapInView({
      places: [["11111111-1111-4111-8111-111111111111", 1, 2, "park", null, 0, "P", [], "w9"]],
      hubs: [],
    });
    expect(v.places[0]?.osmRef).toBe("w9");
  });
});
