#!/usr/bin/env node
// pnpm --filter @ap/collector collect --region atl --dry-run
//
//   --region <id>         a city region from data/cities (repeatable; default: every city)
//   --regions-file <path> JSON array of {id, label, lat, lng, radiusKm, timezone?}: the areas
//                         people use the app in (coverage follows users)
//   --sources-file <path> discovered sources for collector regions in the regions file,
//                         {sources: [{region_id, seed}]} as `regions fetch --sources-out`
//                         writes them; they run like that region's hand-written seeds
//   --dataset <id>        one open-data dataset of data/opendata, alone, in a region covering its
//                         box, on or off (a live check with --dry-run --diagnose)
//   --only-sources        with --sources-file: run only those sources (no city files, no
//                         open-data registry, no API adapters): the verify job's Refresh now
//   --dry-run             print counts only
//   --ingest <base-url>   post each source's items to the collector Edge Function
//                         (https://<ref>.supabase.co/functions/v1/collector, POST /ingest/events)
//                         with the header x-collector-secret from COLLECTOR_SECRET; seeds that
//                         are off are synced too (their rows switch off). Exactly one of
//                         --dry-run and --ingest.
//   --enable              with --ingest: switch the sources on (staging). Without it the
//                         database's enabled flag stands (production sources start off).
//   --run-id <id>         with --ingest: a label for the run (default local-<time>)
//   --summary <path>      write the run's per-source counts as JSON (no item data)
//   --save <path>         write the run's batches (items included) to a local file, so one
//                         collection can be posted to several projects; never print it
//   --from <path>         with --ingest: post the batches a --save run wrote instead of
//                         collecting again (no site is fetched)
//   --window-days <n>     how far ahead to collect (default 60)
//   --max-pages <n>       discovered event pages per page seed (default 25)
//   --slow-host-minutes <n>  time a host whose robots.txt Crawl-delay is over 60 s may take
//                         per run (default 10); its requests are capped to fit, and a delay
//                         longer than this skips the host
//   --max-requests-per-host <n>  requests one host may get per run, robots.txt and
//                         redirects included (default 60); later ones are not sent
//   --max-run-minutes <n> no request starts after this many minutes (default 9), so the
//                         run ends in time however slow its hosts are
//   --denylist-file <path> the database-only denylist (`regions denylist --out` writes it:
//                         hosts and sources removed on an owner's request, migration 63),
//                         merged into data/denylist.json for this run; those sources are skipped
//   --api-budget <path>   the API calls this run may send per adapter, as `regions budget take`
//                         writes them ({"calls": {"ticketmaster": 100}}); an adapter not in it
//                         sends none. Without it only each adapter's paging cap applies.
//   --cache <path>        conditional-GET cache file (default .cache/http.json)
//   --no-cache            do not read or write the cache
//   --list                print the seeds that would run and exit, with no network
//   --json                print the run summary as JSON at the end
//   --diagnose            one stderr line per request: source id, redacted URL, HTTP status,
//                         final host after redirects, media type, byte size, robots.txt
//                         verdict and parser verdict (counts only; no item or page text)
//
// Keys: TICKETMASTER_API_KEY and SEATGEEK_CLIENT_ID turn on the API lane; without them it is
// skipped. COLLECTOR_SECRET is read only with --ingest. No other secrets are read.

import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { API_ADAPTERS, API_HOSTS, enabledAdapters, readApiBudget } from "./adapters/api.ts";
import { collect, type CollectResult, errorKey } from "./collect.ts";
import { citiesFor, loadCities, loadRegions } from "./config.ts";
import { formatDiagnostic, isOrganizerSourceKey, redactForLog } from "./diagnose.ts";
import { FileHttpCache, MemoryHttpCache } from "./net/cache.ts";
import { MAX_REQUESTS_PER_HOST, PoliteFetcher } from "./net/fetcher.ts";
import { readFileSync, writeFileSync } from "node:fs";
import { DryRunIngest, HttpIngest, type Ingest } from "./ingest.ts";
import { discoveredCities } from "./regions.ts";
import { sourceForSeed } from "./sources.ts";
import { Denylist, parseRemoteDenylist } from "./policy/denylist.ts";
import { datasetRegion, datasetSeed, loadRegistry, registrySeeds } from "./opendata-registry.ts";
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
      "sources-file": { type: "string" },
      "dry-run": { type: "boolean", default: false },
      ingest: { type: "string" },
      enable: { type: "boolean", default: false },
      "run-id": { type: "string" },
      summary: { type: "string" },
      save: { type: "string" },
      from: { type: "string" },
      "window-days": { type: "string" },
      "max-pages": { type: "string" },
      "slow-host-minutes": { type: "string" },
      "max-requests-per-host": { type: "string" },
      "max-run-minutes": { type: "string" },
      "api-budget": { type: "string" },
      "denylist-file": { type: "string" },
      "only-sources": { type: "boolean", default: false },
      dataset: { type: "string" },
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

  let cities = loadCities();
  let regions: Region[];
  if (values.dataset) {
    const d = loadRegistry().find((x) => x.id === values.dataset);
    if (!d) throw new Error(`unknown dataset ${values.dataset}`);
    const region = datasetRegion(d);
    regions = [region];
    cities = [{ region, seeds: [{ ...datasetSeed(d), enabled: true }] }];
  } else if (values["regions-file"]) {
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

  if (values["sources-file"]) {
    if (!values["regions-file"]) throw new Error("--sources-file needs --regions-file");
    const d = discoveredCities(JSON.parse(readFileSync(values["sources-file"], "utf8")), regions);
    cities = values["only-sources"] ? d.cities : [...cities, ...d.cities];
    console.error(
      `discovered sources: ${d.cities.reduce((n, c) => n + c.seeds.length, 0)} in ${d.cities.length} region(s), ${d.dropped} dropped`,
    );
  }

  if (values["only-sources"] && !values["sources-file"])
    throw new Error("--only-sources needs --sources-file");
  // Open-data datasets from data/opendata, as seeds of every run region their box overlaps.
  if (!values["only-sources"] && !values.dataset) cities = [...cities, ...registrySeeds(regions)];

  // Hosts and sources removed on an owner's request (database only): never fetched this run.
  const denylist = Denylist.load();
  if (values["denylist-file"]) {
    const remote = parseRemoteDenylist(JSON.parse(readFileSync(values["denylist-file"], "utf8")));
    denylist.merge(remote);
    const skip = new Set(remote.sources);
    cities = cities.map((c) => ({ ...c, seeds: c.seeds.filter((s) => !skip.has(s.id)) }));
    console.error(
      `remote denylist: hosts=${remote.entries.length} sources=${remote.sources.length}`,
    );
  }

  // --only-sources reads no API: no key reaches the run.
  const env = (values["only-sources"] ? {} : process.env) as Record<string, string | undefined>;
  if (values.list) {
    for (const r of regions) {
      console.log(`region ${r.id} (${r.label}) ${r.lat},${r.lng} r=${r.radiusKm}km`);
      for (const c of citiesFor(r, cities)) {
        for (const s of c.seeds)
          console.log(
            `  ${s.enabled === false ? "off" : "on "} ${s.kind.padEnd(7)} ${s.id}  ${redactForLog(s.url, { hidePath: isOrganizerSourceKey(s.id) })}`,
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

  if (values["dry-run"] === Boolean(values.ingest)) {
    console.error("Pass exactly one of --dry-run and --ingest <base-url>.");
    return 2;
  }
  if (values.enable && !values.ingest) throw new Error("--enable needs --ingest");
  if (values.from && !values.ingest) throw new Error("--from needs --ingest");
  const runId = values["run-id"] ?? `local-${Date.now()}`;
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/.test(runId)) throw new Error("bad --run-id");

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
  const apiCalls = values["api-budget"]
    ? readApiBudget(JSON.parse(readFileSync(values["api-budget"], "utf8")))
    : undefined;
  const started = Date.now();
  const fetcher = new PoliteFetcher({
    denylist,
    cache,
    slowHostBudgetMs: slowMinutes * 60_000,
    maxRequestsPerHost: perHost,
    // The API endpoints are limited by the day's call budget, not the per-site cap.
    maxRequestsFor: (host) => (API_HOSTS.has(host) ? 1000 : undefined),
    deadlineAt: started + runMinutes * 60_000,
  });
  const http = values.ingest
    ? new HttpIngest({
        baseUrl: values.ingest.replace(/\/+$/, ""),
        secret: env.COLLECTOR_SECRET ?? "",
        runId,
        enable: values.enable,
      })
    : null;
  const ingest: Ingest = http ?? new DryRunIngest();
  let result: CollectResult;
  if (values.from) {
    const saved = JSON.parse(readFileSync(values.from, "utf8")) as {
      regions: string[];
      result: CollectResult;
    };
    if (saved.regions.join(",") !== regions.map((r) => r.id).join(","))
      throw new Error("--from file was collected for other regions");
    result = saved.result;
  } else {
    result = await collect({
      regions,
      cities,
      fetcher,
      env,
      windowDays,
      maxPagesPerSeed: maxPages,
      apiCalls,
      log: (l) => console.error(l),
      diagnose: values.diagnose ? (e) => console.error(formatDiagnostic(e)) : undefined,
    });
    cache.save();
  }
  if (values.save)
    writeFileSync(values.save, JSON.stringify({ regions: regions.map((r) => r.id), result }));
  const sent: Record<string, Awaited<ReturnType<Ingest["send"]>>> = {};
  for (const b of result.batches) sent[b.sourceKey] = await ingest.send(b);
  if (http) {
    // Seeds that are off still get their row (and switch it off).
    const synced = new Set(result.batches.map((b) => b.sourceKey));
    for (const r of regions)
      for (const c of citiesFor(r, cities))
        for (const seed of c.seeds) {
          if (seed.enabled !== false || synced.has(seed.id)) continue;
          synced.add(seed.id);
          sent[seed.id] = await http.sync(sourceForSeed(seed, c.region));
        }
  }
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
    api: result.stats.api ?? {},
    requests: Object.values(result.stats.requestsByHost).reduce((a, b) => a + b, 0),
    hosts: Object.keys(result.stats.requestsByHost).length,
    seconds: Math.round((Date.now() - started) / 1000),
  };
  if (values.summary) {
    const perSource = result.batches.map((b) => ({
      source: b.sourceKey,
      lane: b.source.lane,
      items: b.items.length,
      complete: b.complete,
      result: sent[b.sourceKey]?.result ?? null,
      error: sent[b.sourceKey]?.error ?? null,
    }));
    const failed = Object.values(sent).filter((r) => r.error).length;
    writeFileSync(
      values.summary,
      JSON.stringify(
        { mode: http ? "ingest" : "dry-run", runId, ...summary, failed, perSource },
        null,
        1,
      ),
    );
  }
  if (values.json) console.log(JSON.stringify(summary));
  else
    console.log(
      `[${http ? "ingest" : "dry-run"}] total sources=${summary.sources} fetched=${summary.fetched} raw=${summary.raw} items=${summary.items} requests=${summary.requests} hosts=${summary.hosts} seconds=${summary.seconds} api=${JSON.stringify(summary.api)} errors=${JSON.stringify(errorsByReason)}`,
    );
  if (http && http.results.some((r) => r.error)) {
    console.error(`${http.results.filter((r) => r.error).length} source(s) failed to post`);
    return 3;
  }
  return 0;
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err: unknown) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  },
);
