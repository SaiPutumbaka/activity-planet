import { describe, expect, it } from "vitest";
import type { TileRow } from "../src/discovery/candidates.ts";
import { locationKey, normalizeLocation, round1 } from "../src/geocode/key.ts";
import { PlaceIndex, similarity, trigrams } from "../src/geocode/match.ts";
import { bbox, geoapifyUrl, nominatimUrl, photonUrl } from "../src/geocode/providers.ts";
import { geocode, MAX_NOMINATIM_PER_RUN } from "../src/geocode/run.ts";
import { parseQueue } from "../src/geocode/service.ts";
import { PoliteFetcher, USER_AGENT } from "../src/net/fetcher.ts";
import { Denylist } from "../src/policy/denylist.ts";
import { fakeClock, fixture } from "./helpers.ts";

const REGION = { lat: 33.749, lng: -84.388, radius_km: 50 };
const job = (n: number, location = `Venue number ${n}, 1 Main St`) => ({
  key: String(n).padStart(64, "0"),
  location,
  region: REGION,
});

/** A transport answering by host, recording every request and the fake clock. */
function transport(
  answer: (url: URL) => { status?: number; body?: string },
  clock: { now: number },
) {
  const log: { url: string; at: number; ua: string }[] = [];
  const t = async (url: string, init: RequestInit) => {
    log.push({
      url,
      at: clock.now,
      ua: (init.headers as Record<string, string>)["user-agent"] ?? "",
    });
    const a = answer(new URL(url));
    return new Response(a.body ?? "", {
      status: a.status ?? 200,
      headers: { "content-type": "application/json" },
    });
  };
  return { t, log };
}

function setup(answer: (url: URL) => { status?: number; body?: string }) {
  const c = fakeClock();
  const { t, log } = transport(answer, c.clock);
  const fetcher = new PoliteFetcher({
    denylist: Denylist.load(),
    transport: t,
    now: c.now,
    sleep: c.sleep,
    maxRequestsFor: () => 1000,
  });
  return { fetcher, log, clock: c.clock, now: c.now };
}

describe("the geocode key matches the SQL helper (supabase/tests/venue_geocoding.sql)", () => {
  it.each([
    [
      "The Earl, 488 Flat Shoals Ave SE",
      33.749,
      -84.388,
      "689ef8895f9f632da96d72c0942c391ee45e8320b252cd8ab72ec5068bfa4b59",
    ],
    [
      "  Café Müller -- Room #2 ",
      51.05,
      13.74,
      "b5be71a6868b2a6ee4db177197c3c2226f898792565331826380097a14dcf760",
    ],
    [
      "CITY HALL (Room 101)",
      -33.86,
      151.21,
      "570a8993b144b57a10c1c107906d41501e2061cd159d483f59a6dcc47fbaeb9b",
    ],
    [
      "Plaza Mayor",
      -0.04,
      -78.45,
      "267ccd55fc532a2038fcba917ebae77d5fc95fae52ac31144f1b50d5c6227114",
    ],
  ])("%s", (text, lat, lng, hex) => {
    expect(locationKey(text, { lat, lng })).toBe(hex);
  });
  it("normalises and rounds like Postgres numeric (half away from zero, no -0.0)", () => {
    expect(normalizeLocation("  Café Müller -- Room #2 ")).toBe("café müller room 2");
    expect([round1(51.05), round1(-0.04), round1(-0.05), round1(-84.35), round1(0.95)]).toEqual([
      "51.1",
      "0.0",
      "-0.1",
      "-84.4",
      "1.0",
    ]);
    expect(locationKey("   ", { lat: 1, lng: 1 })).toBeNull();
  });
});

describe("places first", () => {
  const rows: TileRow[] = [
    [
      "n1",
      -84.3488,
      33.7395,
      "bar",
      "The Earl",
      [],
      "488 Flat Shoals Ave SE",
      "Atlanta",
      null,
      null,
      null,
    ],
    [
      "n2",
      -84.39,
      33.76,
      "arts_venue",
      "Variety Playhouse",
      [],
      "1099 Euclid Ave NE",
      "Atlanta",
      null,
      null,
      null,
    ],
    ["n3", -74.0, 40.71, "bar", "The Earl", [], "1 Far Street", "New York", null, null, null],
  ];
  it("computes pg_trgm-style similarity", () => {
    expect(similarity(trigrams("The Earl"), trigrams("the earl"))).toBe(1);
    expect(similarity(trigrams("Variety Playhouse"), trigrams("The Earl"))).toBeLessThan(0.2);
  });
  it("matches by venue name inside the region only, and sends no request", async () => {
    const idx = new PlaceIndex(rows);
    const m = idx.match("The Earl, 488 Flat Shoals Ave SE, Atlanta, GA", REGION);
    expect(m).toMatchObject({ place_ref: "osm:n1", lat: 33.7395, lng: -84.3488 });
    expect(idx.match("Somewhere Else Entirely", REGION)).toBeNull();
    const { fetcher, log } = setup(() => ({ body: "[]" }));
    const out = await geocode({
      jobs: [job(1, "The Earl, 488 Flat Shoals Ave SE")],
      fetcher,
      placesFor: async () => rows,
      nominatim: true,
    });
    expect(out.results).toEqual([
      expect.objectContaining({ status: "ok", provider: "place", place_ref: "osm:n1" }),
    ]);
    expect(log).toHaveLength(0);
  });
});

describe("Nominatim, Photon and Geoapify", () => {
  it("bounds every request to the region's box and sends the User-Agent", async () => {
    const [w, s, e, n] = bbox(REGION);
    const nom = new URL(nominatimUrl("Test Hall", REGION));
    expect(nom.origin + nom.pathname).toBe("https://nominatim.openstreetmap.org/search");
    expect(nom.searchParams.get("viewbox")).toBe(`${w},${n},${e},${s}`);
    expect(nom.searchParams.get("bounded")).toBe("1");
    expect(nom.searchParams.get("format")).toBe("jsonv2");
    expect(nom.searchParams.get("limit")).toBe("1");
    expect(new URL(photonUrl("Test Hall", REGION)).searchParams.get("bbox")).toBe(
      `${w},${s},${e},${n}`,
    );
    expect(new URL(geoapifyUrl("Test Hall", REGION, "k")).searchParams.get("filter")).toBe(
      `rect:${w},${s},${e},${n}`,
    );
    const { fetcher, log } = setup(() => ({ body: fixture("geocode/nominatim.json") }));
    const out = await geocode({ jobs: [job(1)], fetcher, nominatim: true });
    expect(out.results[0]).toMatchObject({
      status: "ok",
      provider: "nominatim",
      lat: 33.7395,
      place_ref: "osm:n368194721",
    });
    expect(log[0]?.ua).toBe(USER_AGENT);
    expect(USER_AGENT).toContain("/bot");
  });

  it("spaces Nominatim requests at least 2 seconds apart (under its 1 a second) and stops at 300 a night", async () => {
    const { fetcher, log } = setup(() => ({ body: "[]" }));
    const jobs = Array.from({ length: MAX_NOMINATIM_PER_RUN + 5 }, (_, i) => job(i));
    const out = await geocode({ jobs, fetcher, nominatim: true });
    expect(out.calls.nominatim).toBe(MAX_NOMINATIM_PER_RUN);
    expect(log).toHaveLength(MAX_NOMINATIM_PER_RUN);
    for (let i = 1; i < log.length; i++)
      expect(log[i]!.at - log[i - 1]!.at).toBeGreaterThanOrEqual(2000);
    // Answered but nothing found: a miss is recorded (cached 90 days); the 5 not asked wait.
    expect(out.results.filter((r) => r.status === "miss")).toHaveLength(MAX_NOMINATIM_PER_RUN);
    expect(out.counts.left_for_later).toBe(5);
  });

  it("asks Photon only after Nominatim answers 429 or 5xx", async () => {
    for (const status of [429, 503]) {
      const { fetcher, log } = setup((u) =>
        u.hostname === "photon.komoot.io" ? { body: fixture("geocode/photon.json") } : { status },
      );
      const out = await geocode({ jobs: [job(1)], fetcher, nominatim: true });
      expect(out.results[0]).toMatchObject({
        status: "ok",
        provider: "photon",
        place_ref: "osm:w9876",
      });
      expect(log.map((l) => new URL(l.url).hostname)).toEqual([
        "nominatim.openstreetmap.org",
        "photon.komoot.io",
      ]);
    }
    const { fetcher, log } = setup(() => ({ status: 404 }));
    const out = await geocode({ jobs: [job(1)], fetcher, nominatim: true });
    expect(log.map((l) => new URL(l.url).hostname)).toEqual(["nominatim.openstreetmap.org"]);
    expect(out.counts.left_for_later).toBe(1);
  });

  it("skips Geoapify without its key, and uses it first within its grant when the key is set", async () => {
    const a = setup(() => ({ body: "[]" }));
    const out = await geocode({ jobs: [job(1)], fetcher: a.fetcher, nominatim: true });
    expect(out.counts.geoapify_skipped_no_key).toBe(1);
    expect(a.log.some((l) => l.url.includes("geoapify"))).toBe(false);
    const b = setup((u) =>
      u.hostname === "api.geoapify.com"
        ? { body: fixture("geocode/geoapify.json") }
        : { body: "[]" },
    );
    const out2 = await geocode({
      jobs: [job(1), job(2)],
      fetcher: b.fetcher,
      nominatim: true,
      geoapifyKey: "KEY",
      geoapifyCalls: 1,
    });
    expect(out2.results[0]).toMatchObject({ status: "ok", provider: "geoapify", confidence: 0.9 });
    expect(out2.calls).toEqual({ geoapify: 1, nominatim: 1, photon: 0 });
  });

  it("refuses an answer outside the region", async () => {
    const { fetcher } = setup(() => ({ body: fixture("geocode/nominatim-far.json") }));
    const out = await geocode({ jobs: [job(1)], fetcher, nominatim: true });
    expect(out.results[0]).toEqual({ key: job(1).key, status: "miss", provider: "nominatim" });
    expect(out.counts.nominatim_outside_region).toBe(1);
  });

  it("does nothing with Nominatim off (meta.collector_geocode_nominatim)", async () => {
    const { fetcher, log } = setup(() => ({ body: "[]" }));
    const q = parseQueue({
      queue: [{ key: "a".repeat(64), location: "Test Hall", region: REGION }],
      nominatim: "off",
    });
    expect(q.nominatim).toBe(false);
    const out = await geocode({ jobs: q.jobs, fetcher, nominatim: q.nominatim });
    expect(log).toHaveLength(0);
    expect(out.results).toHaveLength(0);
  });
});
