#!/usr/bin/env node
// pnpm --filter collector verify --from https://<ref>.supabase.co/functions/v1/collector \
//   [--limit 50] [--dry-run] [--refresh-out refresh.json] [--regions-out regions.json]
//
// The organizer claim checks that read the claimed site (design 2.3, verify.ts): reads the due
// claims (GET /collector/claims/due), checks each (at most 3 URLs) and posts the outcomes (POST
// /collector/claims/record). With --refresh-out and --regions-out it also writes the connected
// feeds whose owner pressed Refresh now, as a sources file and a regions file for
// `collect --regions-file --sources-file --only-sources`. When nothing is due it says so and
// exits 0 at once. Logs print counts and outcomes only, never a host, a URL or a token.
// COLLECTOR_SECRET is the only secret it reads.

import { writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { PoliteFetcher } from "./net/fetcher.ts";
import { Denylist } from "./policy/denylist.ts";
import { call, checkService, regionFromRow } from "./regions.ts";
import { parseClaims, verifyClaim } from "./verify.ts";

async function main(argv: string[]): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      from: { type: "string" },
      limit: { type: "string" },
      "dry-run": { type: "boolean", default: false },
      "refresh-out": { type: "string" },
      "regions-out": { type: "string" },
    },
    allowPositionals: false,
  });
  if (!values.from) throw new Error("verify needs --from");
  const svc = {
    baseUrl: values.from.replace(/\/+$/, ""),
    secret: process.env.COLLECTOR_SECRET ?? "",
  };
  checkService(svc);
  const limit = values.limit ? Number(values.limit) : 50;
  if (!Number.isInteger(limit) || limit < 1 || limit > 200)
    throw new Error("--limit must be 1..200");

  const { status, body } = await call(svc, `/claims/due?limit=${limit}`);
  if (status === 404) {
    console.log("[verify] route not available yet; nothing to do");
    return 0;
  }
  if (status !== 200) throw new Error(`GET /claims/due failed: ${status}`);
  const claims = parseClaims(body);
  const refresh =
    (body as { refresh?: { regions?: unknown; sources?: unknown } } | null)?.refresh ?? {};
  const refreshSources = Array.isArray(refresh.sources) ? refresh.sources : [];
  const refreshRegions = (Array.isArray(refresh.regions) ? refresh.regions : []).flatMap((r) => {
    try {
      return [regionFromRow(r).region];
    } catch {
      return [];
    }
  });
  if (values["refresh-out"] && values["regions-out"]) {
    writeFileSync(values["refresh-out"], JSON.stringify({ sources: refreshSources }));
    writeFileSync(
      values["regions-out"],
      JSON.stringify({ regions: refreshRegions, resolvedZones: [] }),
    );
  }
  console.log(
    `[verify] claims_due=${claims.length} refresh_sources=${refreshSources.length} refresh_regions=${refreshRegions.length}`,
  );
  if (claims.length === 0) return 0;

  const fetcher = new PoliteFetcher({ denylist: Denylist.load(), maxRequestsPerHost: 10 });
  const results = [];
  const outcomes: Record<string, number> = {};
  for (const job of claims) {
    const r = await verifyClaim(job, fetcher);
    results.push(r);
    const k = r.outcome === "fetch_failed" ? `fetch_failed:${r.reason ?? "?"}` : r.outcome;
    outcomes[k] = (outcomes[k] ?? 0) + 1;
  }
  if (values["dry-run"]) {
    console.log(`[verify] dry run outcomes=${JSON.stringify(outcomes)}`);
    return 0;
  }
  const rec = await call(svc, "/claims/record", {
    method: "POST",
    body: JSON.stringify({ results }),
  });
  if (rec.status !== 200) throw new Error(`POST /claims/record failed: ${rec.status}`);
  console.log(`[verify] outcomes=${JSON.stringify(outcomes)} recorded=${JSON.stringify(rec.body)}`);
  return 0;
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err: unknown) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  },
);
