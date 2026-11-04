#!/usr/bin/env node
// pnpm --filter @ap/collector collect --region atl --dry-run
//
//   --region <id>         a city region from data/cities (repeatable; default: every city)
//   --regions-file <path> JSON array of {id, label, lat, lng, radiusKm, timezone?}: the areas
//                         people use the app in (coverage follows users)
//   --dry-run             print counts only; required until the real ingest is wired
//   --window-days <n>     how far ahead to collect (default 60)
//   --max-pages <n>       discovered event pages per page seed (default 25)
//   --slow-host-minutes <n>  time a host whose robots.txt Crawl-delay is over 60 s may take
//                         per run (default 10); its requests are capped to fit, and a delay
//                         longer than this skips the host
//   --max-requests-per-host <n>  requests one host may get per run, robots.txt and
//                         redirects included (default 60); later ones are not sent
//   --max-run-minutes <n> no request starts after this many minutes (default 9), so the
//                         run ends in time however slow its hosts are
//   --cache <path>        conditional-GET cache file (default .cache/http.json)
//   --no-cache            do not read or write the cache
//   --list                print the seeds that would run and exit, with no network
//   --json                print the run summary as JSON at the end
//   --diagnose            one stderr line per request: source id, redacted URL, HTTP status,
//                         final host after redirects, media type, byte size, robots.txt
//                         verdict and parser verdict (counts only; no item or page text)
//
// Keys: TICKETMASTER_API_KEY and SEATGEEK_CLIENT_ID turn on the API lane; without them it is
// skipped. No other secrets are read.

import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { API_ADAPTERS, enabledAdapters } from "./adapters/api.ts";
import { collect, errorKey } from "./collect.ts";
import { citiesFor, loadCities, loadRegions } from "./config.ts";
import { formatDiagnostic } from "./diagnose.ts";
import { FileHttpCache, MemoryHttpCache } from "./net/cache.ts";
import { MAX_REQUESTS_PER_HOST, PoliteFetcher } from "./net/fetcher.ts";
import { DryRunIngest } from "./ingest.ts";
import { Denylist } from "./policy/denylist.ts";
import type { Region } from "./types.ts";

/** Default --max-run-minutes: the Atlanta run must finish within 10 minutes. */
const DEFAULT_RUN_MINUTES = 9;

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
      "slow-host-minutes": { type: "string" },
      "max-requests-per-host": { type: "string" },
      "max-run-minutes": { type: "string" },
      cache: { type: "string" },
      "no-cache": { type: "boolean", default: false },
      list: { type: "boolean", default: false },
      json: { type: "boolean", default: false },
      diagnose: { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
    allowPositionals: false,
  });
  if (values.help) {
    console.log(
      "usage: collect [--region atl]... [--regions-file regions.json] --dry-run [--window-days 60] [--diagnose] [--list]",
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
  const slowMinutes = values["slow-host-minutes"] ? Number(values["slow-host-minutes"]) : 10;
  if (!Number.isFinite(slowMinutes) || slowMinutes < 0 || slowMinutes > 60)
    throw new Error("--slow-host-minutes must be 0..60");
  const perHost = values["max-requests-per-host"]
    ? Number(values["max-requests-per-host"])
    : MAX_REQUESTS_PER_HOST;
  if (!Number.isInteger(perHost) || perHost < 1 || perHost > 1000)
    throw new Error("--max-requests-per-host must be 1..1000");
  const runMinutes = values["max-run-minutes"]
    ? Number(values["max-run-minutes"])
    : DEFAULT_RUN_MINUTES;
  if (!Number.isFinite(runMinutes) || runMinutes <= 0 || runMinutes > 120)
    throw new Error("--max-run-minutes must be more than 0 and at most 120");

  const cache = values["no-cache"]
    ? new MemoryHttpCache()
    : new FileHttpCache(values.cache ?? DEFAULT_CACHE);
  const started = Date.now();
  const fetcher = new PoliteFetcher({
    denylist: Denylist.load(),
    cache,
    slowHostBudgetMs: slowMinutes * 60_000,
    maxRequestsPerHost: perHost,
    deadlineAt: started + runMinutes * 60_000,
  });
  const ingest = new DryRunIngest();
  const result = await collect({
    regions,
    cities,
    fetcher,
    env,
    windowDays,
    maxPagesPerSeed: maxPages,
    log: (l) => console.error(l),
    diagnose: values.diagnose ? (e) => console.error(formatDiagnostic(e)) : undefined,
  });
  cache.save();
  for (const b of result.batches) await ingest.send(b);
  const errorsByReason: Record<string, number> = {};
  for (const e of result.errors) {
    const k = errorKey(e);
    errorsByReason[k] = (errorsByReason[k] ?? 0) + 1;
  }
  const summary = {
    regions: regions.map((r) => r.id),
    sources: result.stats.sources,
    fetched: result.stats.fetched,
    raw: result.stats.raw,
    items: result.stats.items,
    skipped: result.stats.skipped,
    errors: errorsByReason,
    linksSkipped: result.stats.linksSkipped,
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
