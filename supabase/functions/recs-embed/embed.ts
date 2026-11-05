// recs-embed logic (migration 67, D-045; RECS_DESIGN.md section 4.3). Pure: the model, the clock,
// the RPCs and the log are injected, so the tests pass fakes. Inference is sequential (one
// session, no parallel runs) to keep memory flat; the batch stops at the wall-clock budget and
// leftovers stay leased (retried by the database after 5 minutes). Logs counts and error codes
// only, never a text.

export const DIMENSIONS = 384;

export interface ClaimedRow {
  subject_kind: "hub" | "event" | "coach";
  subject_id: string;
  content_hash: string;
  text: string;
}

export interface RecordedRow {
  kind: ClaimedRow["subject_kind"];
  id: string;
  hash: string;
  embedding: number[];
}

export interface Model {
  run(input: string, options: { mean_pool: boolean; normalize: boolean }): Promise<unknown>;
}

export interface BatchDeps {
  model: Model;
  now: () => number;
  claim: (limit: number) => Promise<ClaimedRow[]>;
  record: (rows: RecordedRow[]) => Promise<number>;
  fail: (row: ClaimedRow, code: string) => Promise<void>;
  log?: (line: string) => void;
}

export interface BatchResult {
  claimed: number;
  embedded: number;
  recorded: number;
  failed: number;
  left: number;
  errors: Record<string, number>;
}

/** An error code for the queue (at most 80 characters of [a-z0-9_]), never a message text. */
export function errorCode(e: unknown): string {
  const raw = e instanceof Error ? e.message : String(e);
  const code = /^[a-z][a-z0-9_]{0,79}$/.test(raw) ? raw : "model_error";
  return code.slice(0, 80);
}

/** A 384-number, finite vector, or an error code. */
export function toVector(v: unknown): number[] {
  const arr = ArrayBuffer.isView(v) ? Array.from(v as unknown as ArrayLike<number>) : v;
  if (!Array.isArray(arr) || arr.length !== DIMENSIONS) throw new Error("bad_dimensions");
  const out = arr.map((x) => Number(x));
  if (out.some((x) => !Number.isFinite(x))) throw new Error("not_finite");
  return out;
}

export interface BatchOptions {
  /** Wall-clock budget for the whole batch. */
  budgetMs?: number;
  /** Rows claimed per request. */
  maxRows?: number;
  /**
   * Budget for the time spent inside the model (inference is CPU-bound, and the Edge Runtime
   * stops a request after about 2 s of CPU), so a batch stops before the limit instead of losing
   * every row it embedded.
   */
  modelBudgetMs?: number;
  /** Record after this many embeddings (1: every row is kept even if the worker is stopped). */
  flushEvery?: number;
}

export async function runBatch(
  deps: BatchDeps,
  {
    budgetMs = 50_000,
    maxRows = 24,
    modelBudgetMs = Number.POSITIVE_INFINITY,
    flushEvery = Number.POSITIVE_INFINITY,
  }: BatchOptions = {},
): Promise<BatchResult> {
  const started = deps.now();
  const rows = await deps.claim(maxRows);
  let pending: RecordedRow[] = [];
  const errors: Record<string, number> = {};
  let embedded = 0;
  let recorded = 0;
  let failed = 0;
  let left = 0;
  let modelMs = 0;
  const flush = async () => {
    if (pending.length) {
      const batch = pending;
      pending = [];
      recorded += await deps.record(batch);
    }
  };
  for (const [i, row] of rows.entries()) {
    if (deps.now() - started > budgetMs || modelMs > modelBudgetMs) {
      left = rows.length - i; // still leased; retried after 5 minutes
      break;
    }
    const t0 = deps.now();
    try {
      const out = await deps.model.run(row.text, { mean_pool: true, normalize: true });
      modelMs += deps.now() - t0;
      pending.push({
        kind: row.subject_kind,
        id: row.subject_id,
        hash: row.content_hash,
        embedding: toVector(out),
      });
      embedded++;
    } catch (e) {
      modelMs += deps.now() - t0;
      const code = errorCode(e);
      errors[code] = (errors[code] ?? 0) + 1;
      failed++;
      await deps.fail(row, code);
    }
    if (pending.length >= flushEvery) await flush();
  }
  await flush();
  const result = { claimed: rows.length, embedded, recorded, failed, left, errors };
  deps.log?.(`recs-embed ${JSON.stringify(result)}`);
  return result;
}

export type Rpc = (name: string, args: Record<string, unknown>) => Promise<unknown>;

/** The request handler, with I/O injected (index.ts wires the real ones). */
export function createHandler(opts: {
  rpc: Rpc | null;
  model: () => Model;
  now?: () => number;
  log?: (line: string) => void;
  batch?: BatchOptions;
}): (req: Request) => Promise<Response> {
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  return async (req) => {
    if (req.method !== "POST") return json({ error: "not_found" }, 404);
    const rpc = opts.rpc;
    if (!rpc) return json({ error: "misconfigured" }, 500);
    const secret = req.headers.get("x-recs-secret") ?? "";
    let allowed = false;
    try {
      allowed =
        secret.length >= 32 &&
        (await rpc("recs_embed_verify_secret", { p_secret: secret })) === true;
    } catch {
      opts.log?.("recs-embed: secret check failed");
      return json({ error: "secret_check_failed" }, 500);
    }
    await req.body?.cancel();
    if (!allowed) return json({ error: "unauthorized" }, 401);
    try {
      const result = await runBatch(
        {
          model: opts.model(),
          now: opts.now ?? Date.now,
          claim: async (limit) =>
            ((await rpc("recs_embed_claim", { p_limit: limit })) ?? []) as ClaimedRow[],
          record: async (rows) => Number(await rpc("recs_embed_record", { p_rows: rows })) || 0,
          fail: async (row, code) => {
            await rpc("recs_embed_fail", {
              p_kind: row.subject_kind,
              p_id: row.subject_id,
              p_error: code,
            });
          },
          log: opts.log,
        },
        opts.batch,
      );
      return json(result);
    } catch (e) {
      opts.log?.(`recs-embed: run failed ${errorCode(e)}`);
      return json({ error: "run_failed" }, 500);
    }
  };
}
