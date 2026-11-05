import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { env } from "node:process";
import { afterEach, describe, expect, it } from "vitest";

import { decodeMapInView, loadMapView, resetPlaceFilesBackoff, type MapAdapter } from "../map";
import {
  decodeTileFile,
  filePlaceDetail,
  readJsonBody,
  resetFilePlaces,
  searchPlaces,
  type PlaceFileLoader,
} from "../place-files";

/**
 * Region trial (D-042 slice 12): the app's own map code on a real region's files. Runs only in
 * .github/workflows/region-trial.yml, which sets REGION_TRIAL_DIR to a folder holding:
 *   report.json  scripts/places/region_trial.py's decoded report: map_in_view answers from staging
 *                as a signed-out visitor, each view and hub chip read from Postgres (`:db`) and
 *                with the static files (`:files`, the trial's built files counted as published
 *                inside a rolled-back transaction), plus `refs` (place id to OSM ref)
 *   site/        the places-files build of the region's tiles (the workflow artifact)
 *   trial.json   the trial (views, home, searches)
 * For every answer that names files, loadMapView reads them from site/ exactly as the app reads
 * them from GitHub Pages, and the places must be the same OSM places Postgres gave. Writes
 * app.json (counts only; no names) for the job's summary. Skipped everywhere else.
 */

const dir = env.REGION_TRIAL_DIR ?? "";
const enabled = dir !== "" && existsSync(join(dir, "report.json"));

interface Trial {
  home: [number, number];
  views: Record<string, [number, number, number, number]>;
  hubs: string[];
  searches: string[];
}

function siteLoader(site: string, read: Map<string, number>): PlaceFileLoader {
  return {
    async load(path) {
      const bytes = readFileSync(join(site, path));
      read.set(path, bytes.length);
      return readJsonBody(new Uint8Array(bytes));
    },
  };
}

function walk(d: string): string[] {
  return readdirSync(d).flatMap((n) => {
    const p = join(d, n);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

afterEach(() => {
  resetPlaceFilesBackoff();
  resetFilePlaces();
});

describe.skipIf(!enabled)("region trial: the app reads the region's files", () => {
  it("every view from the files shows the places Postgres shows", async () => {
    const report = JSON.parse(readFileSync(join(dir, "report.json"), "utf8")) as Record<
      string,
      unknown
    >;
    const trial = JSON.parse(readFileSync(join(dir, "trial.json"), "utf8")) as Trial;
    const refs = (report.refs ?? {}) as Record<string, string | null>;
    const site = join(dir, "site");
    const read = new Map<string, number>();
    const out: Record<string, unknown> = { views: {} };
    const views = out.views as Record<string, unknown>;
    const mismatches: string[] = [];

    const keys = Object.keys(report)
      .filter((k) => k.startsWith("view:") && k.endsWith(":files"))
      .sort();
    for (const key of keys) {
      const [, vname, hname] = key.split(":") as [string, string, string];
      const filesAnswer = report[key] as Record<string, unknown>;
      const dbAnswer = report[`view:${vname}:${hname}:db`] as Record<string, unknown>;
      const dbView = decodeMapInView(dbAnswer);
      const bbox = trial.views[vname] as [number, number, number, number];
      const [west, south, east, north] = bbox;
      const hubIds = hname === "all" ? null : dbView.hubs.map((h) => h.id);
      const adapter: MapAdapter = {
        async mapInView(args) {
          return args.p_files ? filesAnswer : dbAnswer;
        },
        async placesInView() {
          return null;
        },
        async placeDetail() {
          return null;
        },
      };
      const named = Boolean(filesAnswer.place_files);
      const view = await loadMapView(
        adapter,
        { bbox: { west, south, east, north }, hubIds, generic: false, when: "week" },
        {
          filesBase: existsSync(site) ? "https://files.test/" : null,
          loader: siteLoader(site, read),
        },
      );
      const fromFiles = view.places.filter((p) => p.id.startsWith("o:")).length;
      const want = new Set(
        dbView.places.map((p) => refs[p.id] ?? `db:${p.id}`).filter((r) => r !== null),
      );
      const got = new Set(view.places.map((p) => p.osmRef ?? `db:${p.id}`));
      const missing = [...want].filter((r) => !got.has(r)).length;
      const extra = [...got].filter((r) => !want.has(r)).length;
      if (named && (missing || extra)) mismatches.push(`${vname}:${hname} -${missing} +${extra}`);
      views[`${vname}:${hname}`] = {
        files_named: named,
        postgres_places: dbView.places.length,
        app_places: view.places.length,
        from_files: fromFiles,
        missing,
        extra,
        truncated: view.truncated,
        mapping: view.mapping,
        hubs: view.hubs.map((h) => h.slug),
        plans: view.plans.length,
        shows: view.shows.length,
      };
    }

    // Search on the files the app read (the list panel's "Find a place by name").
    const [lat, lng] = trial.home;
    const searches: Record<string, number> = {};
    for (const term of trial.searches) {
      searches[term] = searchPlaces(term, [], { lat, lng }, 1000).length;
    }
    out.searches = searches;

    // The files themselves: rows, bytes and what a place card can show.
    if (existsSync(site)) {
      const tiles: Record<string, unknown> = {};
      for (const f of walk(join(site, "places")).filter((p) => p.endsWith(".json.gz"))) {
        const bytes = readFileSync(f);
        const json = await readJsonBody(new Uint8Array(bytes));
        const raw = JSON.stringify(json).length;
        const file = decodeTileFile(json);
        const card = file.rows[0] ? filePlaceDetail(file.rows[0].osmRef) : null;
        tiles[String(file.tile)] = {
          gzip_bytes: bytes.length,
          json_bytes: raw,
          rows: file.rows.length,
          bytes_per_row: file.rows.length
            ? Math.round((bytes.length / file.rows.length) * 10) / 10
            : 0,
          with_address: file.rows.filter((r) => r.address).length,
          with_hours: file.rows.filter((r) => r.hours).length,
          with_website: file.rows.filter((r) => r.website).length,
          kinds: Object.fromEntries(
            Object.entries(
              file.rows.reduce<Record<string, number>>((m, r) => {
                m[r.kind] = (m[r.kind] ?? 0) + 1;
                return m;
              }, {}),
            )
              .sort((a, b) => b[1] - a[1])
              .slice(0, 12),
          ),
          card_from_file: card ? { hubs: card.hubs.length, source: card.source } : null,
        };
      }
      out.files = tiles;
      out.read = Object.fromEntries(read);
    }
    writeFileSync(join(dir, "app.json"), JSON.stringify(out));
    expect(mismatches).toEqual([]);
  });
});
