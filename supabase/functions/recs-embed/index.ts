// recs-embed: embeds queued hubs, events and coach listings with Supabase's built-in gte-small
// model (migration 67, D-045; the logic is in embed.ts).
//
//   POST /recs-embed {}  -> claims up to recs_embed_batch due rows, embeds them one after another
//                           (mean_pool, normalize; 384 numbers), records them. Answers counts only.
//
// The caller is the database (pg_cron job recs-embed every minute, through pg_net and
// public.recs_embed_dispatch), not a user, so the gateway JWT check is off (config.toml). Every
// request must carry x-recs-secret, checked through recs_embed_verify_secret (vault secret
// recs_embed_secret, generated inside the database by migration 67). No API key and no vendor:
// the model runs inside the Edge Runtime. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected
// by Supabase. Logs counts and error codes only, never a text.
import { createHandler, type Model, type Rpc } from "./embed.ts";

interface EdgeAi {
  ai: { Session: new (model: string) => Model };
}

let session: Model | null = null;

/** Loaded once per worker and reused across requests. */
function model(): Model {
  if (!session) {
    const supa = (globalThis as unknown as { Supabase?: EdgeAi }).Supabase;
    if (!supa) throw new Error("model_unavailable");
    session = new supa.ai.Session("gte-small");
  }
  return session;
}

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const rpc: Rpc | null =
  supabaseUrl && serviceKey
    ? async (name, args) => {
        const res = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
          method: "POST",
          headers: {
            apikey: serviceKey,
            Authorization: `Bearer ${serviceKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(args),
        });
        const text = await res.text();
        if (!res.ok) throw new Error(`rpc_${name}_http_${res.status}`);
        return text ? JSON.parse(text) : null;
      }
    : null;

Deno.serve(
  createHandler({
    rpc,
    model,
    log: (line) => console.log(line),
    // Staging showed the Edge Runtime's CPU limit (about 2 s a request) stopping 24-row batches
    // before anything was recorded: claim a few rows, stop after about 1.2 s inside the model and
    // record every row as soon as it is embedded. Unprocessed rows stay leased for 5 minutes.
    batch: { maxRows: 6, budgetMs: 50_000, modelBudgetMs: 1_200, flushEvery: 1 },
  }),
);
