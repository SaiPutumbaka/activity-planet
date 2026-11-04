// The daily call budget of the lane 1 APIs (D-042 slice 10, docs/design/auto-coverage
// AUTO_COVERAGE_DESIGN.md 7): Ticketmaster 1,000 calls a UTC day (its free key allows 5,000), and
// SeatGeek 1,000. The budget lives in the database the regions come from (collector_budget rows
// ticketmaster_calls and seatgeek_calls), so manual runs and the nightly run share it.
//
//   takeApiBudget    POST <base>/api-budget         (collector_api_budget_take): before the run,
//                    per adapter whose key is set, regions x pages, granted up to what is left
//   settleApiBudget  POST <base>/api-budget/return  (collector_api_budget_return): after the
//                    run, the calls granted but not sent go back to that day
//
// Without a key an adapter asks for nothing and the file says 0 for it: a clean no-op.

import { API_ADAPTERS, type ApiAdapter, callsWanted, enabledAdapters } from "./adapters/api.ts";
import { call, checkService, type ServiceOptions } from "./regions.ts";
import type { Region } from "./types.ts";

export interface ApiBudgetFile {
  /** Granted calls per adapter id (0 for an adapter without a key or without budget left). */
  calls: Record<string, number>;
  /** The UTC day each grant was taken from, for the return. */
  days: Record<string, string>;
  /** Adapters whose key is set. */
  on: string[];
}

/** The regions API adapters run for: every region of the run except seeds-only city areas. */
export function apiRegionCount(regions: Region[]): number {
  return regions.filter((r) => !r.seedsOnly).length;
}

export async function takeApiBudget(
  opts: ServiceOptions,
  env: Record<string, string | undefined>,
  regions: number,
  adapters: ApiAdapter[] = API_ADAPTERS,
): Promise<ApiBudgetFile> {
  const file: ApiBudgetFile = { calls: {}, days: {}, on: [] };
  for (const a of adapters) file.calls[a.id] = 0;
  const on = enabledAdapters(env, adapters);
  if (on.length === 0 || regions < 1) return file;
  checkService(opts);
  for (const { adapter } of on) {
    file.on.push(adapter.id);
    const wanted = callsWanted(adapter, regions);
    if (wanted < 1) continue;
    const { status, body } = await call(opts, "/api-budget", {
      method: "POST",
      body: JSON.stringify({ api: adapter.id, calls: wanted }),
    });
    const b = (body ?? {}) as Record<string, unknown>;
    if (status !== 200 || typeof b.granted !== "number" || typeof b.day !== "string")
      throw new Error(`POST /api-budget failed for ${adapter.id}: ${status}`);
    file.calls[adapter.id] = b.granted;
    file.days[adapter.id] = b.day;
  }
  return file;
}

/** Calls granted but not sent, per adapter (never negative). */
export function unusedCalls(
  file: ApiBudgetFile,
  used: Record<string, { calls: number } | undefined>,
): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [id, granted] of Object.entries(file.calls)) {
    if (!file.days[id] || granted < 1) continue;
    const left = granted - (used[id]?.calls ?? 0);
    if (left > 0) out[id] = left;
  }
  return out;
}

export async function settleApiBudget(
  opts: ServiceOptions,
  file: ApiBudgetFile,
  used: Record<string, { calls: number } | undefined>,
): Promise<Record<string, number>> {
  const back = unusedCalls(file, used);
  if (Object.keys(back).length === 0) return back;
  checkService(opts);
  for (const [id, calls] of Object.entries(back)) {
    const { status } = await call(opts, "/api-budget/return", {
      method: "POST",
      body: JSON.stringify({ api: id, day: file.days[id], calls }),
    });
    if (status !== 200) throw new Error(`POST /api-budget/return failed for ${id}: ${status}`);
  }
  return back;
}
