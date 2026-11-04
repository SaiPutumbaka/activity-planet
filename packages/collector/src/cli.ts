#!/usr/bin/env node
// pnpm --filter @ap/collector collect --region atl --dry-run
//
//   --region <id>         a city region from data/cities (repeatable; default: every city)
//   --regions-file <path> JSON array of {id, label, lat, lng, radiusKm, timezone?}: the areas
//                         people use the app in (coverage follows users)
//   --dry-run             print counts only; required until the real ingest is wired
//   --window-days <n>     how far ahead to collect (default 60)
//   --max-pages <n>       discovered event pages per page seed (default 25)
//   --cache <path>        conditional-GET cache file (default .cache/http.json)
//   --no-cache            do not read or write the cache
//   --list                print the seeds that would run and exit, with no network
//   --json                print the run summary as JSON at the end
//
// Keys: TICKETMASTER_API_KEY and SEATGEEK_CLIENT_ID turn on the API lane; without them it is
// skipped. No other secrets are read.

import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { API_ADAPTERS, enabledAdapters } from "./adapters/api.ts";
import { collect } from "./collect.ts";
import { citiesFor, loadCities, loadRegions } from "./config.ts";
import { FileHttpCache, MemoryHttpCache } from "./net/cache.ts";
import { PoliteFetcher } from "./net/fetcher.ts";
import { DryRunIngest } from "./ingest.ts";
import { Denylist } from "./policy/denylist.ts";
import type { Region } from "./types.ts";

const DEFAULT_CACHE = fileURLToPath(new URL("../.cache/http.json", import.meta.url));

async function main(argv: string[]): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      region: { type: "string", multiple: true },
      "regions-file": { type: "string" },
      "dry-run": { type: "boolean", default: false },
      "window-days": { type: "string" },
      "max-pages": { type: "string" },
      cache: { type: "string" },
      "no-cache": { type: "boolean", default: false },
      list: { type: "boolean", default: false },
      json: { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
    allowPositionals: false,
  });
  if (values.help) {
    console.log(
      "usage: collect [--region atl]... [--regions-file regions.json] --dry-run [--window-days 60] [--list]",
    );
    return 0;
  }

  const cities = loadCities();
  let regions: Region[];
  if (values["regions-file"]) {
    regions = loadRegions(values["regions-file"]);
  } else if (values.region?.length) {
    regions = values.region.map((id) => {
      const city = cities.find((c) => c.region.id === id);
      if (!city)
        throw new Error(
          `unknown region ${id}; known: ${cities.map((c) => c.region.id).join(", ")}`,
        );
      return city.region;
    });
  } else {
    regions = cities.map((c) => c.region);
  }

  const env = process.env as Record<string, string | undefined>;
  if (values.list) {
    for (const r of regions) {
      console.log(`region ${r.id} (${r.label}) ${r.lat},${r.lng} r=${r.radiusKm}km`);
      for (const c of citiesFor(r, cities)) {
        for (const s of c.seeds)
          console.log(
            `  ${s.enabled === false ? "off" : "on "} ${s.kind.padEnd(7)} ${s.id}  ${s.url}`,
          );
      }
    }
    const on = enabledAdapters(env).map((a) => a.adapter.id);
    for (const a of API_ADAPTERS)
      console.log(
        `  api ${on.includes(a.id) ? "on " : "off"} ${a.id} (${a.envKey}${on.includes(a.id) ? " set" : " unset"})`,
      );
    return 0;
  }

  if (!values["dry-run"]) {
    console.error(
      "The real ingest is not wired yet (it lands with the collector schema). Run with --dry-run.",
    );
    return 2;
  }

  const windowDays = values["window-days"] ? Number(values["window-days"]) : 60;
  if (!Number.isFinite(windowDays) || windowDays < 1 || windowDays > 180)
    throw new Error("--window-days must be 1..180");
  const maxPages = values["max-pages"] ? Number(values["max-pages"]) : undefined;

  const cache = values["no-cache"]
    ? new MemoryHttpCache()
    : new FileHttpCache(values.cache ?? DEFAULT_CACHE);
  const fetcher = new PoliteFetcher({ denylist: Denylist.load(), cache });
  const ingest = new DryRunIngest();
  const started = Date.now();
  const result = await collect({
    regions,
    cities,
    fetcher,
    env,
    windowDays,
    maxPagesPerSeed: maxPages,
    log: (l) => console.error(l),
  });
  cache.save();
  for (const b of result.batches) await ingest.send(b);
  const errorsByReason: Record<string, number> = {};
  for (const e of result.errors) errorsByReason[e.reason] = (errorsByReason[e.reason] ?? 0) + 1;
  const summary = {
    regions: regions.map((r) => r.id),
    sources: result.stats.sources,
    fetched: result.stats.fetched,
    raw: result.stats.raw,
    items: result.stats.items,
    skipped: result.stats.skipped,
    errors: errorsByReason,
    requests: Object.values(result.stats.requestsByHost).reduce((a, b) => a + b, 0),
    hosts: Object.keys(result.stats.requestsByHost).length,
    seconds: Math.round((Date.now() - started) / 1000),
  };
  if (values.json) console.log(JSON.stringify(summary));
  else
    console.log(
      `[dry-run] total sources=${summary.sources} fetched=${summary.fetched} raw=${summary.raw} items=${summary.items} requests=${summary.requests} hosts=${summary.hosts} seconds=${summary.seconds} errors=${JSON.stringify(errorsByReason)}`,
    );
  return 0;
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err: unknown) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  },
);
