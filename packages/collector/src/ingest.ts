// Where a run's batches go. DryRunIngest prints counts. HttpIngest posts each source's complete
// item set to the collector Edge Function (POST <base>/ingest/events, header x-collector-secret),
// which calls collector_ingest_events: the source's feed_sources row is created or updated from
// the seed, then import_upsert_batch runs on the items. Logs carry counts only, never items.

import type { SourceInfo } from "./sources.ts";
import type { SourceBatch } from "./types.ts";

export interface IngestResult {
  sourceKey: string;
  sent: number;
  /** collector_ingest_events' counts (inserted, updated, linked_duplicates, ...), when posted. */
  result?: Record<string, unknown>;
  error?: string;
}

export interface Ingest {
  readonly name: string;
  send(batch: SourceBatch): Promise<IngestResult>;
}

const counts = (r: Record<string, number>) =>
  Object.entries(r)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${k}=${v}`)
    .join(",");

export class DryRunIngest implements Ingest {
  readonly name = "dry-run";
  readonly lines: string[] = [];
  private readonly out: (line: string) => void;

  constructor(out: (line: string) => void = (l) => console.log(l)) {
    this.out = out;
  }

  async send(batch: SourceBatch): Promise<IngestResult> {
    const withPoint = batch.items.filter((i) => i.lat !== null).length;
    const cancelled = batch.items.filter((i) => i.cancelled).length;
    const line = `[dry-run] source=${batch.sourceKey} region=${batch.regionId} items=${batch.items.length} with_point=${withPoint} cancelled=${cancelled} complete=${batch.complete} skipped={${counts(batch.skipped)}} errors={${counts(batch.errors ?? {})}}`;
    this.lines.push(line);
    this.out(line);
    return { sourceKey: batch.sourceKey, sent: 0 };
  }
}

/** The largest item set one request carries (routes.ts MAX_EVENT_ITEMS). */
export const MAX_EVENT_ITEMS = 2000;

/** Result keys printed per source: counts and flags only. */
const RESULT_KEYS = [
  "enabled",
  "created",
  "complete",
  "total",
  "inserted",
  "updated",
  "unchanged",
  "linked_duplicates",
  "missed",
  "cancelled",
  "handed_off",
  "repeat_run",
] as const;

export interface HttpIngestOptions {
  /** https://<ref>.supabase.co/functions/v1/collector */
  baseUrl: string;
  secret: string;
  runId: string;
  /** Switch sources on (staging). Production leaves enabled as the database has it. */
  enable: boolean;
  fetch?: typeof fetch;
  out?: (line: string) => void;
}

export class HttpIngest implements Ingest {
  readonly name = "http";
  readonly results: IngestResult[] = [];
  private readonly opts: HttpIngestOptions;
  private readonly out: (line: string) => void;

  constructor(opts: HttpIngestOptions) {
    if (!/^https:\/\/[^/]+\/functions\/v1\/collector$/.test(opts.baseUrl))
      throw new Error("ingest base URL must be https://<host>/functions/v1/collector");
    if (opts.secret.length < 32) throw new Error("COLLECTOR_SECRET is missing or too short");
    this.opts = opts;
    this.out = opts.out ?? ((l) => console.log(l));
  }

  /** Creates or updates a source's row without items (a seed that is off). */
  async sync(source: SourceInfo): Promise<IngestResult> {
    return this.post(source, [], [], true, `${source.slug}`);
  }

  async send(batch: SourceBatch): Promise<IngestResult> {
    if (batch.items.length > MAX_EVENT_ITEMS) {
      const r: IngestResult = { sourceKey: batch.sourceKey, sent: 0, error: "batch_too_large" };
      this.results.push(r);
      this.out(
        `[ingest] source=${batch.sourceKey} error=batch_too_large items=${batch.items.length}`,
      );
      return r;
    }
    return this.post(batch.source, batch.items, batch.seen ?? [], batch.complete, batch.sourceKey);
  }

  private async post(
    source: SourceInfo,
    items: unknown[],
    seen: string[],
    complete: boolean,
    key: string,
  ): Promise<IngestResult> {
    const f = this.opts.fetch ?? fetch;
    let status = 0;
    let body: Record<string, unknown> = {};
    // A 5xx can come back after collector_ingest_events committed (a gateway timeout). The
    // retry carries the same run_id, so the database reads it as a repeat of this run's post for
    // the source and counts no missed runs a second time.
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        const res = await f(`${this.opts.baseUrl}/ingest/events`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-collector-secret": this.opts.secret,
          },
          body: JSON.stringify({
            run_id: this.opts.runId,
            source,
            items,
            seen,
            complete,
            enable: this.opts.enable,
          }),
        });
        status = res.status;
        const text = await res.text();
        try {
          body = text ? (JSON.parse(text) as Record<string, unknown>) : {};
        } catch {
          body = {};
        }
        if (status < 500) break;
      } catch {
        status = 0;
      }
      if (attempt < 3) await new Promise((r) => setTimeout(r, 2000 * attempt));
    }
    const r: IngestResult = { sourceKey: key, sent: items.length };
    if (status === 200) {
      r.result = body;
      const fields = RESULT_KEYS.filter((k) => k in body).map((k) => `${k}=${String(body[k])}`);
      const skipped = body.skipped && typeof body.skipped === "object" ? body.skipped : {};
      this.out(
        `[ingest] source=${key} sent=${items.length} ${fields.join(" ")} skipped={${counts(skipped as Record<string, number>)}}`,
      );
    } else {
      const err = typeof body.error === "string" ? body.error.replace(/[^\w-]/g, "_") : "failed";
      r.error = `${status}:${err}`;
      this.out(`[ingest] source=${key} sent=${items.length} error=${r.error}`);
    }
    this.results.push(r);
    return r;
  }
}
