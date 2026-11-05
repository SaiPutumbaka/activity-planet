#!/usr/bin/env node
// The nightly run's regions (D-042 slice 6). Both commands need COLLECTOR_SECRET and talk only to
// the collector Edge Function; they print counts, never a region's point.
//
//   pnpm --filter collector regions fetch --from https://<ref>.supabase.co/functions/v1/collector \
//     --out regions.json [--sources-out sources.json] [--all] [--limit 20]
//       Due collector regions (or every one with --all), zones looked up offline where the row
//       has none, plus the area of every city file that contains one (seeds only). With
//       --sources-out, the discovered sources the database lists for them (probation, enabled
//       and paused sources due a retry; migration 46).
//
//   pnpm --filter collector regions record --to https://<ref>.supabase.co/functions/v1/collector \
//     --regions regions.json --batches batches.json --run-id <id> [--sources sources.json]
//       After the run was posted: per collector region, the sources and items it got, and the
//       zone looked up for it, stamped on the row (collector_regions_record). With --sources, each
//       discovered source's result (items inside its region, outcome) goes to the lifecycle
//       (POST /collector/sources/record): one good UTC day is probation, two enable it.
//
//   pnpm --filter collector regions budget take --to <base> --out api-budget.json
//     (--regions regions.json | --region-count N)
//       The lane 1 API calls this run may send (D-042 slice 10): for each adapter whose key is
//       set (TICKETMASTER_API_KEY, SEATGEEK_CLIENT_ID), regions x pages from the day's budget.
//       Without any key nothing is requested and every adapter gets 0.
//
//   pnpm --filter collector regions budget settle --to <base> --budget api-budget.json \
//     --summary collected.json
//       After the run: the calls granted but not sent go back to that day's budget.
//
//   pnpm --filter collector regions denylist --from <base> --out denylist-remote.json
//       The database-only denylist (hosts and sources removed on an owner's request, migration
//       63) for `collect --denylist-file`. Prints counts only.
//
//   pnpm --filter collector regions geocode --to <base> [--limit 300] [--max-minutes 8] \
//     [--dry-run]
//       Venue geocoding (design 2.5, migration 63): the queue of imported events still on their
//       area centroid, our own places first, then Geoapify (GEOAPIFY_SERVER_KEY, its daily budget)
//       and Nominatim (300 a night, Photon after a 429 or 5xx), answers recorded. --dry-run asks
//       the providers but records nothing. Counts by provider and outcome only, never a text.
//
//   pnpm --filter collector regions runs record --to <base> --job <job> --run-id <id> \
//     --outcome ok|partial|failed [--stats summary.json] [--started-at <iso>]
//       The run's record for the health panel (collector_job_runs): counts only. A 404 (an older
//       function) is ignored.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import {
  apiRegionCount,
  type ApiBudgetFile,
  settleApiBudget,
  takeApiBudget,
} from "./api-budget.ts";
import type { CollectResult } from "./collect.ts";
import { loadCities } from "./config.ts";
import { fetchTileRows } from "./discovery/discover.ts";
import { geocode } from "./geocode/run.ts";
import { fetchGeocodeQueue, recordGeocodes } from "./geocode/service.ts";
import { Denylist } from "./policy/denylist.ts";
import { PoliteFetcher } from "./net/fetcher.ts";
import { flatCounts, JOBS, type Job, type Outcome, recordRun } from "./runs.ts";
import {
  call,
  citySeedCount,
  fetchRegions,
  fetchRemoteDenylist,
  fetchSources,
  recordRegions,
  recordSources,
  regionCounts,
  sourceResults,
  withCityRegions,
} from "./regions.ts";
import type { Region } from "./types.ts";

interface RegionsFile {
  regions: Region[];
  /** Collector regions whose zone this run looked up (the record step stores it). */
  resolvedZones: string[];
}

async function main(argv: string[]): Promise<number> {
  const [command, sub, ...afterSub] = argv;
  const rest = command === "budget" || command === "runs" ? afterSub : argv.slice(1);
  const { values } = parseArgs({
    args: rest,
    options: {
      from: { type: "string" },
      to: { type: "string" },
      out: { type: "string" },
      "sources-out": { type: "string" },
      all: { type: "boolean", default: false },
      limit: { type: "string" },
      regions: { type: "string" },
      batches: { type: "string" },
      sources: { type: "string" },
      "run-id": { type: "string" },
      "region-count": { type: "string" },
      budget: { type: "string" },
      summary: { type: "string" },
      job: { type: "string" },
      outcome: { type: "string" },
      stats: { type: "string" },
      "started-at": { type: "string" },
      "max-minutes": { type: "string" },
      "dry-run": { type: "boolean", default: false },
    },
    allowPositionals: false,
  });
  const secret = process.env.COLLECTOR_SECRET ?? "";

  if (command === "fetch") {
    if (!values.from || !values.out) throw new Error("fetch needs --from and --out");
    const limit = values.limit ? Number(values.limit) : 20;
    if (!Number.isInteger(limit) || limit < 1 || limit > 100)
      throw new Error("--limit must be 1..100");
    const baseUrl = values.from.replace(/\/+$/, "");
    const resolved = await fetchRegions({ baseUrl, secret, all: values.all, limit });
    const collectorRegions = resolved.map((r) => r.region);
    const cities = loadCities();
    const regions = withCityRegions(collectorRegions, cities);
    const file: RegionsFile = {
      regions,
      resolvedZones: resolved.filter((r) => r.timezoneResolved).map((r) => r.region.id),
    };
    writeFileSync(values.out, JSON.stringify(file));
    let discovered = "not written";
    if (values["sources-out"]) {
      const s = await fetchSources(
        { baseUrl, secret },
        collectorRegions.map((r) => r.id),
      );
      writeFileSync(values["sources-out"], JSON.stringify({ sources: s.sources }));
      discovered = s.available ? String(s.sources.length) : "route not available yet (0)";
    }
    console.log(
      `[regions] collector=${collectorRegions.length} city_areas=${regions.length - collectorRegions.length} zones_looked_up=${file.resolvedZones.length} without_zone=${collectorRegions.filter((r) => !r.timezone).length} city_seeds=${citySeedCount(regions, cities)} discovered_sources=${discovered}`,
    );
    return 0;
  }

  if (command === "record") {
    if (!values.to || !values.regions || !values.batches || !values["run-id"])
      throw new Error("record needs --to, --regions, --batches and --run-id");
    const runId = values["run-id"];
    if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/.test(runId)) throw new Error("bad --run-id");
    const file = JSON.parse(readFileSync(values.regions, "utf8")) as RegionsFile;
    const saved = JSON.parse(readFileSync(values.batches, "utf8")) as {
      regions: string[];
      result: CollectResult;
    };
    if (saved.regions.join(",") !== file.regions.map((r) => r.id).join(","))
      throw new Error("--batches file was collected for other regions");
    const zones = new Set(file.resolvedZones);
    const entries = regionCounts(file.regions, saved.result.batches).map((c) => {
      const tz = file.regions.find((r) => r.id === c.id)?.timezone;
      return zones.has(c.id) && tz ? { ...c, timezone: tz } : c;
    });
    if (entries.length === 0) {
      console.log("[regions] no collector regions in this run; nothing recorded");
      return 0;
    }
    const result = await recordRegions(
      { baseUrl: values.to.replace(/\/+$/, ""), secret, runId },
      entries,
    );
    const withItems = entries.filter((e) => e.items > 0).length;
    console.log(
      `[regions] recorded=${entries.length} with_items=${withItems} without_items=${entries.length - withItems} result=${JSON.stringify(result)}`,
    );
    if (values.sources) {
      const results = sourceResults(
        JSON.parse(readFileSync(values.sources, "utf8")),
        file.regions,
        saved.result.batches,
      );
      if (results.length === 0) {
        console.log("[sources] no discovered sources in this run; nothing recorded");
      } else {
        const lifecycle = await recordSources(
          { baseUrl: values.to.replace(/\/+$/, ""), secret, runId },
          results,
        );
        const byOutcome: Record<string, number> = {};
        for (const r of results) byOutcome[r.outcome] = (byOutcome[r.outcome] ?? 0) + 1;
        console.log(
          `[sources] recorded=${results.length} outcomes=${JSON.stringify(byOutcome)} result=${JSON.stringify(lifecycle)}`,
        );
      }
    }
    return 0;
  }

  if (command === "budget" && sub === "take") {
    if (!values.to || !values.out) throw new Error("budget take needs --to and --out");
    let count: number;
    if (values.regions) {
      count = apiRegionCount(
        (JSON.parse(readFileSync(values.regions, "utf8")) as RegionsFile).regions,
      );
    } else {
      count = Number(values["region-count"] ?? "");
      if (!Number.isInteger(count) || count < 0 || count > 100)
        throw new Error("budget take needs --regions or --region-count 0..100");
    }
    const file = await takeApiBudget(
      { baseUrl: values.to.replace(/\/+$/, ""), secret },
      process.env as Record<string, string | undefined>,
      count,
    );
    writeFileSync(values.out, JSON.stringify(file));
    console.log(
      `[api] regions=${count} on=${file.on.length ? file.on.join(",") : "none (no key set; lane 1 skipped)"} granted=${JSON.stringify(file.calls)}`,
    );
    return 0;
  }

  if (command === "budget" && sub === "settle") {
    if (!values.to || !values.budget) throw new Error("budget settle needs --to and --budget");
    const file = JSON.parse(readFileSync(values.budget, "utf8")) as ApiBudgetFile;
    // Without the run's summary the calls sent are unknown: nothing goes back (the grant stands).
    if (!values.summary || !existsSync(values.summary)) {
      console.log("[api] no run summary; nothing returned");
      return 0;
    }
    const used =
      (
        JSON.parse(readFileSync(values.summary, "utf8")) as {
          api?: Record<string, { calls: number }>;
        }
      ).api ?? {};
    const back = await settleApiBudget(
      { baseUrl: values.to.replace(/\/+$/, ""), secret },
      file,
      used,
    );
    console.log(
      `[api] used=${JSON.stringify(Object.fromEntries(Object.entries(used).map(([k, v]) => [k, v.calls])))} returned=${JSON.stringify(back)}`,
    );
    return 0;
  }

  if (command === "denylist") {
    if (!values.from || !values.out) throw new Error("denylist needs --from and --out");
    const r = await fetchRemoteDenylist({ baseUrl: values.from.replace(/\/+$/, ""), secret });
    writeFileSync(values.out, JSON.stringify(r.denylist));
    console.log(
      `[denylist] remote=${r.available ? "yes" : "route not available yet"} hosts=${r.denylist.entries.length} sources=${r.denylist.sources.length}`,
    );
    return 0;
  }

  if (command === "geocode") {
    if (!values.to) throw new Error("geocode needs --to");
    const baseUrl = values.to.replace(/\/+$/, "");
    const svc = { baseUrl, secret };
    const limit = values.limit ? Number(values.limit) : 300;
    if (!Number.isInteger(limit) || limit < 1 || limit > 500)
      throw new Error("--limit must be 1..500");
    const minutes = values["max-minutes"] ? Number(values["max-minutes"]) : 8;
    if (!Number.isFinite(minutes) || minutes <= 0 || minutes > 30)
      throw new Error("--max-minutes must be more than 0 and at most 30");
    const started = Date.now();
    const q = await fetchGeocodeQueue(svc, limit);
    if (!q.available || q.jobs.length === 0) {
      console.log(
        `[geocode] queue=${q.jobs.length}${q.available ? "" : " (route not available yet)"}; nothing to do`,
      );
      return 0;
    }
    // Geoapify only with its key, within the day's budget (collector_budget geoapify_geocode_calls).
    const key = (process.env.GEOAPIFY_SERVER_KEY ?? "").trim() || null;
    let granted = 0;
    if (key && !values["dry-run"]) {
      const { status, body } = await call(svc, "/api-budget", {
        method: "POST",
        body: JSON.stringify({ api: "geoapify_geocode", calls: Math.min(300, q.jobs.length) }),
      });
      const b = (body ?? {}) as { granted?: unknown };
      granted = status === 200 && typeof b.granted === "number" ? b.granted : 0;
    }
    const fetcher = new PoliteFetcher({
      denylist: Denylist.load(),
      deadlineAt: started + minutes * 60_000,
      maxRequestsFor: () => 400,
    });
    const rowsCache = new Map<string, Awaited<ReturnType<typeof fetchTileRows>>["rows"]>();
    const out = await geocode({
      jobs: q.jobs,
      fetcher,
      placesFor: async (r) => {
        const k = `${r.lat},${r.lng},${r.radius_km}`;
        let rows = rowsCache.get(k);
        if (!rows) {
          try {
            rows = (
              await fetchTileRows(svc, {
                id: "geocode",
                label: "geocode",
                lat: r.lat,
                lng: r.lng,
                radiusKm: r.radius_km,
              })
            ).rows;
          } catch {
            rows = [];
          }
          rowsCache.set(k, rows);
        }
        return rows;
      },
      geoapifyKey: key,
      geoapifyCalls: granted,
      nominatim: q.nominatim,
      deadlineAt: started + minutes * 60_000,
    });
    if (key && granted > out.calls.geoapify && !values["dry-run"]) {
      const day = new Date().toISOString().slice(0, 10);
      await call(svc, "/api-budget/return", {
        method: "POST",
        body: JSON.stringify({ api: "geoapify_geocode", day, calls: granted - out.calls.geoapify }),
      }).catch(() => undefined);
    }
    const recorded = values["dry-run"] ? { dry_run: 1 } : await recordGeocodes(svc, out.results);
    console.log(
      `[geocode] queue=${q.jobs.length} nominatim=${q.nominatim ? "on" : "off"} geoapify=${key ? `key set, granted ${granted}` : "skipped: no key"} calls=${JSON.stringify(out.calls)} outcomes=${JSON.stringify(out.counts)} recorded=${JSON.stringify(recorded)}`,
    );
    return 0;
  }

  if (command === "runs" && sub === "record") {
    if (!values.to || !values.job || !values["run-id"] || !values.outcome)
      throw new Error("runs record needs --to, --job, --run-id and --outcome");
    if (!JOBS.includes(values.job as Job))
      throw new Error(`--job must be one of ${JOBS.join(", ")}`);
    if (!["ok", "partial", "failed"].includes(values.outcome))
      throw new Error("--outcome must be ok, partial or failed");
    let stats: Record<string, number | boolean> = {};
    if (values.stats && existsSync(values.stats)) {
      try {
        stats = flatCounts(JSON.parse(readFileSync(values.stats, "utf8")));
      } catch {
        stats = {};
      }
    }
    const r = await recordRun(
      { baseUrl: values.to.replace(/\/+$/, ""), secret },
      {
        job: values.job as Job,
        run_id: values["run-id"],
        outcome: values.outcome as Outcome,
        ...(values["started-at"] ? { started_at: values["started-at"] } : {}),
        stats,
      },
    );
    console.log(
      `[runs] job=${values.job} outcome=${values.outcome} recorded=${r.recorded}${r.recorded ? "" : " (route not available yet)"}`,
    );
    return 0;
  }

  console.error(
    "usage: regions fetch|record|denylist|geocode|budget take|budget settle|runs record ... (see src/regions-cli.ts)",
  );
  return 2;
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err: unknown) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  },
);
