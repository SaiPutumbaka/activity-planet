import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

import { decodePlaceHealth, formatBytes, percentOf, sizeMessage } from "../place-health";
import { hiddenMapLayers } from "../shows";

const RAW = {
  tiles: {
    by_status: { active: 3, idle: 1 },
    total: 4,
    list: [
      {
        id: 178031,
        status: "active",
        keep: true,
        rows: 9119,
        demand: 0,
        osm_run_at: "2026-11-04T10:00:00+00:00",
        geoapify_run_at: null,
        last_member_at: "2026-11-04T00:00:00+00:00",
        idle_since: null,
        west: -84.5,
        south: 33.5,
      },
    ],
  },
  rows: [
    { source: "osm", status: "active", public: true, n: 16693 },
    { source: "user", status: "pending", public: true, n: 2 },
  ],
  size: {
    places_bytes: 27787264,
    db_bytes: 68812800,
    alarm_bytes: 125829120,
    cap_bytes: 157286400,
    db_cap_bytes: 471859200,
    level: "ok",
  },
  runs: {
    extract: { finished_at: "2026-11-04T10:00:00Z", tile_id: 178031, received: 9119 },
    geoapify: null,
    retire: { ran_at: "2026-11-04T04:23:00Z", stats: { idled: 1, retired: 0 } },
    size: null,
    dump: {
      ran_at: "2026-11-04T05:41:00Z",
      stats: { month: "2026-11", rows: 16693, published: false },
    },
    cron: [
      {
        job: "retire-place-tiles",
        schedule: "23 4 * * *",
        active: true,
        last_start: null,
        last_status: null,
      },
    ],
  },
  budget: [],
  budget_caps: { geoapify_places: 500 },
};

describe("decodePlaceHealth", () => {
  it("reads every part of mod_place_health", () => {
    const h = decodePlaceHealth(RAW);
    expect(h.tilesByStatus).toEqual({ wanted: 0, filling: 0, active: 3, idle: 1, retired: 0 });
    expect(h.tilesTotal).toBe(4);
    expect(h.tiles[0]).toMatchObject({
      id: 178031,
      status: "active",
      keep: true,
      rows: 9119,
      west: -84.5,
    });
    expect(h.tiles[0]?.osmRunAt?.toISOString()).toBe("2026-11-04T10:00:00.000Z");
    expect(h.tiles[0]?.geoapifyRunAt).toBeNull();
    expect(h.rowsTotal).toBe(16695);
    expect(h.size.level).toBe("ok");
    expect(h.runs.extract).toMatchObject({ tileId: 178031, received: 9119 });
    expect(h.runs.geoapify).toBeNull();
    expect(h.runs.retire?.stats.idled).toBe(1);
    expect(h.runs.dump?.stats.month).toBe("2026-11");
    expect(h.runs.cron[0]).toMatchObject({
      job: "retire-place-tiles",
      active: true,
      lastStart: null,
    });
    // A source with a cap but no credits used today still shows, at zero.
    expect(h.budget).toEqual([{ source: "geoapify_places", used: 0, cap: 500 }]);
  });

  it("never throws on a missing or odd answer", () => {
    const h = decodePlaceHealth(null);
    expect(h.tilesTotal).toBe(0);
    expect(h.tiles).toEqual([]);
    expect(h.size.level).toBe("ok");
    expect(h.size.capBytes).toBe(157_286_400);
    expect(decodePlaceHealth({ size: { level: "boom" } }).size.level).toBe("ok");
    expect(
      decodePlaceHealth({ tiles: { list: [{ id: 1, status: "nope" }] } }).tiles[0]?.status,
    ).toBe("wanted");
  });
});

describe("size helpers", () => {
  it("formats bytes and percentages", () => {
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(17_825_792)).toBe("17.0 MB");
    expect(percentOf(125_829_120, 157_286_400)).toBe(80);
    expect(percentOf(5, 0)).toBe(0);
    expect(percentOf(300, 100)).toBe(100);
  });

  it("says what each level means", () => {
    const size = decodePlaceHealth(RAW).size;
    expect(sizeMessage(size)).toMatch(/under the 120 MB alarm/);
    expect(sizeMessage({ ...size, level: "alarm" })).toMatch(/static-file fallback/);
    expect(sizeMessage({ ...size, level: "cap" })).toMatch(/at the cap/);
  });
});

describe("hiddenMapLayers (shows and games, slice 10)", () => {
  it("hides the shows chip until a show exists", () => {
    expect(hiddenMapLayers(false, 0)).toEqual(["shows"]);
    expect(hiddenMapLayers(undefined, 0)).toEqual(["shows"]);
    expect(hiddenMapLayers(true, 0)).toEqual([]);
    expect(hiddenMapLayers(false, 2)).toEqual([]);
  });
});
