#!/usr/bin/env node
// Automatic source discovery (D-042 slice 8, docs/design/auto-coverage AUTO_COVERAGE_DESIGN.md 6).
// Every command talks only to the collector Edge Function (COLLECTOR_SECRET) and to the sites it
// probes, through the PoliteFetcher (robots.txt, one request per 2 s per host, the denylist, an
// identifying User-Agent). Logs carry counts; only the gate prints hosts (Atlanta's public
// organisation sites). No region point is ever printed.
//
//   pnpm --filter collector discover gate --from https://<ref>.supabase.co/functions/v1/collector \
//     [--out gate.json] [--record --run-id <id>] [--max-hosts 150] [--no-wikidata]
//       The quality gate (design 6.4): Atlanta from scratch. Candidates come only from the OSM
//       website tags of the region's place tiles (GET /collector/tiles/{id}/rows) and Wikidata;
//       no seed URL, no stored candidate, no HTTP cache. The best caps.probeHostsPerRegionPerDay
//       are probed, and the run must find a calendar on at least gate.required of the gate.expected
//       sites. Exit 1 when it does not. With --record the result goes to
//       POST /collector/discovery/gate under this code's hash, which opens the probe queue.
//
//   pnpm --filter collector discover status --from <base>
//       Exit 0 when this probe code passed the gate on that project within 30 days, else 3.
//
//   pnpm --filter collector discover candidates --from <base> [--limit 10]
//       Builds candidates for the collector regions due (GET /collector/discovery/regions: never
//       built or built 30 days ago, 10 a night), skipping regions in the EU gate's countries and
//       the sites of hand-written seeds, posts them (POST /collector/candidates) and stamps the
//       regions (POST /collector/discovery/regions/record).
//
//   pnpm --filter collector discover probe --from <base> --run-id <id> [--per-region 150]
//       Probes the candidates the database offers (GET /collector/discovery/queue, refused until
//       the gate passed for this code) and posts each result to the lifecycle
//       (POST /collector/sources/record, run id probe-<id>).

import { writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { loadCities } from "./config.ts";
import { loadDiscoveryConfig } from "./discovery/config.ts";
import {
  buildCandidates,
  fetchTileRows,
  foundCalendar,
  gateReport,
  probeAll,
} from "./discovery/discover.ts";
import { euGated, zoneCountry } from "./discovery/eu.ts";
import { probeHostAllowance, type ProbeInput, type ProbeResult } from "./discovery/probe.ts";
import { probeHash } from "./discovery/version.ts";
import { MemoryHttpCache } from "./net/cache.ts";
import { PoliteFetcher } from "./net/fetcher.ts";
import { Denylist } from "./policy/denylist.ts";
import { call, regionFromRow, type ServiceOptions } from "./regions.ts";
import type { Region } from "./types.ts";
import { hostOf, siteOf } from "./util/url.ts";

const RUN_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,90}$/;

function fetcherFor(minutes: number, denylist: Denylist, perHost?: number): PoliteFetcher {
  return new PoliteFetcher({
    denylist,
    // From scratch: nothing remembered from earlier runs.
    cache: new MemoryHttpCache(),
    deadlineAt: Date.now() + minutes * 60_000,
    // Each candidate host is probed once a run: its run-wide allowance is the probe's cap.
    ...(perHost ? { maxRequestsFor: probeHostAllowance(perHost) } : {}),
  });
}

function tally(results: ProbeResult[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const r of results) out[r.outcome] = (out[r.outcome] ?? 0) + 1;
  return out;
}

/** The hand-written seeds' sites: discovery never proposes them again (duplicates, design 6.3). */
function seedSites(): Set<string> {
  const out = new Set<string>();
  for (const c of loadCities()) for (const s of c.seeds) out.add(siteOf(hostOf(s.url)));
  return out;
}

async function main(argv: string[]): Promise<number> {
  const [command, ...rest] = argv;
  const { values } = parseArgs({
    args: rest,
    options: {
      from: { type: "string" },
      out: { type: "string" },
      record: { type: "boolean", default: false },
      "run-id": { type: "string" },
      "max-hosts": { type: "string" },
      "no-wikidata": { type: "boolean", default: false },
      limit: { type: "string" },
      "per-region": { type: "string" },
    },
    allowPositionals: false,
  });
  if (!values.from) throw new Error(`${command ?? "discover"} needs --from`);
  const svc: ServiceOptions = {
    baseUrl: values.from.replace(/\/+$/, ""),
    secret: process.env.COLLECTOR_SECRET ?? "",
  };
  const cfg = loadDiscoveryConfig();
  const caps = cfg.caps;
  const denylist = Denylist.load();
  const hash = probeHash();
  const now = new Date();

  if (command === "status") {
    const gate = await call(svc, `/discovery/gate?hash=${hash}`);
    if (gate.status !== 200) throw new Error(`GET /discovery/gate failed: ${gate.status}`);
    const open = (gate.body as { open?: unknown })?.open === true;
    console.log(`[gate] probe_hash=${hash} open=${open}`);
    return open ? 0 : 3;
  }

  if (command === "gate") {
    const city = loadCities().find((c) => c.region.id === cfg.gate.city);
    if (!city) throw new Error(`gate city ${cfg.gate.city} has no city file`);
    const region = city.region;
    const maxHosts = values["max-hosts"]
      ? Number(values["max-hosts"])
      : caps.probeHostsPerRegionPerDay;
    if (!Number.isInteger(maxHosts) || maxHosts < 1 || maxHosts > 2000)
      throw new Error("bad --max-hosts");
    if (values.record && !RUN_ID.test(values["run-id"] ?? ""))
      throw new Error("--record needs --run-id");
    const started = Date.now();
    const fetcher = fetcherFor(caps.probeRunMinutes, denylist, caps.requestsPerHostPerProbe);
    const tiles = await fetchTileRows(svc, region);
    const built = await buildCandidates({
      region,
      rows: tiles.rows,
      fetcher,
      denylist,
      caps: { ...caps, candidatesPerRegion: Math.max(caps.candidatesPerRegion, maxHosts) },
      country: zoneCountry(region.timezone),
      wikidata: !values["no-wikidata"],
    });
    console.log(
      `[gate] probe_hash=${hash} tiles=${tiles.tiles} tiles_with_rows=${tiles.tilesWithRows} rows=${tiles.rows.length} ${Object.entries(
        built.counts,
      )
        .map(([k, v]) => `${k}=${v}`)
        .join(" ")}`,
    );
    const inputs = built.candidates.slice(0, maxHosts);
    const expectedSites = new Set(cfg.gate.expected.map((e) => e.site));
    for (const e of cfg.gate.expected) {
      const i = built.candidates.findIndex((c) => siteOf(c.host) === e.site);
      const c = built.candidates[i];
      console.log(
        `[gate] candidate ${e.site}: ${c ? `rank=${i + 1} host=${c.host} origin=${c.origin} kind=${c.place_kind ?? "-"} score=${c.score}${i >= maxHosts ? " (beyond the cap)" : ""}` : "none"}`,
      );
    }
    const results = await probeAll(inputs, {
      region,
      fetcher,
      now,
      caps,
      onResult: (r) => {
        const mark = expectedSites.has(siteOf(r.candidate.host)) ? " *" : "";
        if (mark || foundCalendar(r))
          console.log(
            `[probe] ${r.candidate.host}${mark} outcome=${r.outcome} kind=${r.kind ?? "-"} platform=${r.platform ?? "-"} platforms=${r.platforms.join(",") || "-"} items=${r.items} in_region=${r.in_region} requests=${r.requests} errors=${r.errors} score=${r.score} notes=${r.notes.join("|")}`,
          );
      },
    });
    const report = gateReport(results, built.candidates, cfg.gate.expected, cfg.gate.required);
    const found = results.filter(foundCalendar);
    const counts: Record<string, number> = {
      tiles: tiles.tiles,
      rows: tiles.rows.length,
      candidates: built.candidates.length,
      probed: results.length,
      calendars: found.length,
      calendars_with_items: found.filter((r) => r.outcome === "ok").length,
      requests: Object.values(Object.fromEntries(fetcher.requests)).reduce((a, b) => a + b, 0),
      hosts: fetcher.requests.size,
      seconds: Math.round((Date.now() - started) / 1000),
      ...Object.fromEntries(Object.entries(tally(results)).map(([k, v]) => [`outcome_${k}`, v])),
      ...Object.fromEntries(Object.entries(built.counts).map(([k, v]) => [`build_${k}`, v])),
    };
    for (const r of report.rows)
      console.log(
        `[gate] ${r.found ? "FOUND " : "missed"} ${r.seed} (${r.site}) candidate=${r.candidate ? "yes" : "no"} outcome=${r.outcome ?? "-"} kind=${r.kind ?? "-"} platform=${r.platform ?? "-"} in_region=${r.in_region}`,
      );
    console.log(`[gate] counts ${JSON.stringify(counts)}`);
    console.log(
      `[gate] ${report.passed ? "PASS" : "FAIL"} rediscovered ${report.found} of ${report.expected} (required ${report.required}; ${report.foundWithItems} with items, ${report.found - report.foundWithItems} needs_permission)`,
    );
    if (values.out)
      writeFileSync(
        values.out,
        JSON.stringify(
          {
            probe_hash: hash,
            report,
            counts,
            results: results.map((r) => ({
              ...r,
              candidate: {
                host: r.candidate.host,
                origin: r.candidate.origin,
                place_kind: r.candidate.place_kind,
              },
            })),
          },
          null,
          1,
        ),
      );
    if (values.record) {
      const { status, body } = await call(svc, "/discovery/gate", {
        method: "POST",
        body: JSON.stringify({
          run_id: values["run-id"],
          probe_hash: hash,
          region: cfg.gate.city,
          expected: report.expected,
          required: report.required,
          found: report.found,
          found_sites: report.rows.filter((r) => r.found).map((r) => r.site),
          counts,
        }),
      });
      if (status !== 200) throw new Error(`POST /discovery/gate failed: ${status}`);
      console.log(`[gate] recorded ${JSON.stringify(body)}`);
    }
    return report.passed ? 0 : 1;
  }

  if (command === "candidates") {
    const limit = values.limit ? Number(values.limit) : caps.newRegionsPerDay;
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error("bad --limit");
    const { status, body } = await call(svc, `/discovery/regions?limit=${limit}`);
    const rows = (body as { regions?: unknown[] } | null)?.regions;
    if (status !== 200 || !Array.isArray(rows))
      throw new Error(`GET /discovery/regions failed: ${status}`);
    const skip = seedSites();
    const fetcher = fetcherFor(caps.probeRunMinutes, denylist);
    const stamped: string[] = [];
    const sum: Record<string, number> = {
      regions: rows.length,
      eu_gated: 0,
      added: 0,
      known: 0,
      denied: 0,
      invalid: 0,
    };
    for (const row of rows) {
      const { region } = regionFromRow(row);
      stamped.push(region.id);
      if (euGated(region.timezone, cfg.euGate)) {
        sum.eu_gated = (sum.eu_gated ?? 0) + 1;
        continue;
      }
      const tiles = await fetchTileRows(svc, region);
      const built = await buildCandidates({
        region,
        rows: tiles.rows,
        fetcher,
        denylist,
        caps,
        country: zoneCountry(region.timezone),
        skipSites: skip,
      });
      for (let i = 0; i < built.candidates.length; i += 500) {
        const chunk = built.candidates.slice(i, i + 500).map((c) => ({
          url: c.url,
          origin: c.origin,
          region_id: region.id,
          ...(c.name ? { name: c.name } : {}),
          ...(c.place_kind ? { place_kind: c.place_kind } : {}),
          ...(c.wikidata_id ? { wikidata_id: c.wikidata_id } : {}),
          ...(c.country ? { country: c.country } : {}),
          score: c.score,
        }));
        const r = await call(svc, "/candidates", {
          method: "POST",
          body: JSON.stringify({ candidates: chunk }),
        });
        if (r.status !== 200) throw new Error(`POST /candidates failed: ${r.status}`);
        for (const [k, v] of Object.entries(r.body as Record<string, unknown>))
          if (typeof v === "number") sum[k] = (sum[k] ?? 0) + v;
      }
      console.log(
        `[candidates] region=${region.id} tiles=${tiles.tiles} rows=${tiles.rows.length} ${Object.entries(
          built.counts,
        )
          .map(([k, v]) => `${k}=${v}`)
          .join(" ")}`,
      );
    }
    if (stamped.length > 0) {
      const r = await call(svc, "/discovery/regions/record", {
        method: "POST",
        body: JSON.stringify({ regions: stamped }),
      });
      if (r.status !== 200) throw new Error(`POST /discovery/regions/record failed: ${r.status}`);
    }
    console.log(`[candidates] ${JSON.stringify(sum)}`);
    return 0;
  }

  if (command === "probe") {
    const runId = values["run-id"] ?? "";
    if (!RUN_ID.test(runId)) throw new Error("probe needs --run-id");
    const per = values["per-region"]
      ? Number(values["per-region"])
      : caps.probeHostsPerRegionPerDay;
    if (!Number.isInteger(per) || per < 1 || per > 500) throw new Error("bad --per-region");
    const gate = await call(svc, `/discovery/gate?hash=${hash}`);
    if (gate.status !== 200) throw new Error(`GET /discovery/gate failed: ${gate.status}`);
    if ((gate.body as { open?: unknown })?.open !== true) {
      console.log(
        `[probe] gate closed for probe_hash=${hash}: run "discover gate --record" first (last: ${JSON.stringify((gate.body as { last?: unknown })?.last ?? null)})`,
      );
      return 3;
    }
    const q = await call(svc, `/discovery/queue?hash=${hash}&per_region=${per}&limit=2000`);
    const list = (q.body as { candidates?: unknown[] } | null)?.candidates;
    if (q.status !== 200 || !Array.isArray(list))
      throw new Error(`GET /discovery/queue failed: ${q.status}`);
    const rr = await call(svc, "/regions?due=0&limit=100");
    const regionRows = (rr.body as { regions?: unknown[] } | null)?.regions;
    if (rr.status !== 200 || !Array.isArray(regionRows))
      throw new Error(`GET /regions failed: ${rr.status}`);
    const regions = new Map<string, Region>(
      regionRows.map((row) => {
        const { region } = regionFromRow(row);
        return [region.id, region];
      }),
    );
    const byRegion = new Map<string, (ProbeInput & { id: string })[]>();
    let skipped = 0;
    for (const e of list as Record<string, unknown>[]) {
      const region = regions.get(String(e.region_id));
      if (
        !region ||
        typeof e.id !== "string" ||
        typeof e.url !== "string" ||
        typeof e.host !== "string"
      ) {
        skipped++;
        continue;
      }
      // Second layer of the EU gate: the database already leaves these out.
      if (euGated(region.timezone, cfg.euGate) && e.origin !== "member") {
        skipped++;
        continue;
      }
      const input = {
        id: e.id,
        url: e.url,
        host: e.host,
        origin: String(e.origin),
        name: (e.name as string | null) ?? null,
        place_kind: (e.place_kind as string | null) ?? null,
        wikidata_id: (e.wikidata_id as string | null) ?? null,
        country: (e.country as string | null) ?? zoneCountry(region.timezone),
        score: Number(e.score ?? 0),
      };
      byRegion.set(region.id, [...(byRegion.get(region.id) ?? []), input]);
    }
    const fetcher = fetcherFor(caps.probeRunMinutes, denylist, caps.requestsPerHostPerProbe);
    const all: { r: ProbeResult; id: string }[] = [];
    for (const [rid, inputs] of byRegion) {
      const region = regions.get(rid) as Region;
      const results = await probeAll(inputs.slice(0, per), { region, fetcher, now, caps });
      results.forEach((r, i) => all.push({ r, id: (inputs[i] as { id: string }).id }));
      console.log(
        `[probe] region=${rid} probed=${results.length} outcomes=${JSON.stringify(tally(results))}`,
      );
    }
    const toPost = all
      .filter(({ r }) => !r.deadline)
      .map(({ r, id }) => ({
        candidate_id: id,
        outcome: r.outcome,
        ...(r.kind ? { kind: r.kind } : {}),
        ...(r.url ? { url: r.url } : {}),
        ...(r.platform ? { platform: r.platform } : {}),
        items: r.items,
        in_region: r.in_region,
        requests: r.requests,
        errors: r.errors,
        complete: r.complete,
      }));
    const lifecycle: Record<string, number> = {};
    for (let i = 0; i < toPost.length; i += 500) {
      const res = await call(svc, "/sources/record", {
        method: "POST",
        body: JSON.stringify({ run_id: `probe-${runId}`, results: toPost.slice(i, i + 500) }),
      });
      if (res.status !== 200) throw new Error(`POST /sources/record failed: ${res.status}`);
      for (const [k, v] of Object.entries(res.body as Record<string, unknown>))
        if (typeof v === "number") lifecycle[k] = (lifecycle[k] ?? 0) + v;
    }
    console.log(
      `[probe] queue=${list.length} skipped=${skipped} probed=${all.length} deadline=${all.length - toPost.length} posted=${toPost.length} lifecycle=${JSON.stringify(lifecycle)}`,
    );
    return 0;
  }

  console.error(
    "usage: discover gate|candidates|probe --from <collector base URL> (see src/discover-cli.ts)",
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
