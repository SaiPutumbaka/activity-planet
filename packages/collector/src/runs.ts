// Job run records for the health panel (migration 63, collector_job_runs): each workflow's last
// step (if: always()) posts its run with counts only (POST /collector/runs/record). A 404 (an
// older Edge Function or a project without migration 63) is ignored, so the jobs keep working.

import { call, checkService, type ServiceOptions } from "./regions.ts";

export const JOBS = ["ingest", "discovery", "verify", "places_extract", "places_files"] as const;
export type Job = (typeof JOBS)[number];
export type Outcome = "ok" | "partial" | "failed";

/** Flat counts from a summary object: numbers and booleans, keys a-z0-9_, at most 60. */
export function flatCounts(src: unknown, prefix = ""): Record<string, number | boolean> {
  const out: Record<string, number | boolean> = {};
  const walk = (v: unknown, p: string, depth: number) => {
    if (Object.keys(out).length >= 60) return;
    if (typeof v === "number" && Number.isFinite(v)) out[p] = v;
    else if (typeof v === "boolean") out[p] = v;
    else if (v && typeof v === "object" && !Array.isArray(v) && depth < 2)
      for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
        const key = `${p ? `${p}_` : ""}${k}`
          .toLowerCase()
          .replace(/[^a-z0-9_]/g, "_")
          .slice(0, 40);
        if (/^[a-z0-9_]{1,40}$/.test(key)) walk(x, key, depth + 1);
      }
  };
  walk(src, prefix, 0);
  return out;
}

export async function recordRun(
  opts: ServiceOptions,
  run: {
    job: Job;
    run_id: string;
    outcome: Outcome;
    started_at?: string;
    stats?: Record<string, number | boolean | string>;
  },
): Promise<{ recorded: boolean; status: number }> {
  checkService(opts);
  if (!JOBS.includes(run.job)) throw new Error(`unknown job ${run.job}`);
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/.test(run.run_id)) throw new Error("bad run id");
  const { status } = await call(opts, "/runs/record", {
    method: "POST",
    body: JSON.stringify(run),
  });
  if (status === 404) return { recorded: false, status };
  if (status !== 200) throw new Error(`POST /runs/record failed: ${status}`);
  return { recorded: true, status };
}
