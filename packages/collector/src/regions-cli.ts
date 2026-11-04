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

import { readFileSync, writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import {
  apiRegionCount,
  type ApiBudgetFile,
  settleApiBudget,
  takeApiBudget,
} from "./api-budget.ts";
import type { CollectResult } from "./collect.ts";
import { loadCities } from "./config.ts";
import {
  citySeedCount,
  fetchRegions,
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
  const rest = command === "budget" ? afterSub : argv.slice(1);
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
    const used = values.summary
      ? ((
          JSON.parse(readFileSync(values.summary, "utf8")) as {
            api?: Record<string, { calls: number }>;
          }
        ).api ?? {})
      : {};
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

  console.error(
    "usage: regions fetch|record|budget take|budget settle ... (see src/regions-cli.ts)",
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
