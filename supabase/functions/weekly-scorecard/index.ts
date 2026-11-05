// weekly-scorecard: the Monday counts-only email to the founder (migration 67, D-045; PLAN.md
// 4.12; the logic is in scorecard.ts).
//
//   POST /weekly-scorecard {week_start?}  -> skipped_no_key, already_sent, sent or failed.
//
// The caller is the database (pg_cron job weekly-scorecard, Monday 12:07 UTC, through pg_net and
// public.scorecard_dispatch), not a user, so the gateway JWT check is off (config.toml). Every
// request must carry x-scorecard-secret, checked through scorecard_verify_secret (vault secret
// scorecard_secret, generated inside the database by migration 67).
//
// Optional project secrets (Supabase Edge Function secrets, never in a file):
//   RESEND_API_KEY, SCORECARD_TO   without either the run is recorded as skipped_no_key
//   NOTIFY_EMAIL_FROM              sender (default notifications@activityplanet.app)
//   APP_URL                        admin panel link base (default https://app.activityplanet.app)
//   POSTHOG_URL                    optional link for imported-shelf clicks
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by Supabase.
import { FROM, sendResendEmails } from "../send-notifications/resend.ts";
import { type Rpc, runScorecard, validWeek } from "./scorecard.ts";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function httpsUrl(value: string | undefined, fallback: string): string {
  try {
    const u = new URL(value ?? fallback);
    return u.protocol === "https:" ? u.origin + u.pathname.replace(/\/$/, "") : fallback;
  } catch {
    return fallback;
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "not_found" }, 404);
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ error: "misconfigured" }, 500);

  const rpc: Rpc = async (name, args) => {
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
  };

  const secret = req.headers.get("x-scorecard-secret") ?? "";
  let allowed = false;
  try {
    allowed =
      secret.length >= 32 && (await rpc("scorecard_verify_secret", { p_secret: secret })) === true;
  } catch (err) {
    console.error("weekly-scorecard: secret check failed", String(err).slice(0, 120));
    return json({ error: "secret_check_failed" }, 500);
  }
  let week: string | null = null;
  try {
    week = validWeek(((await req.json()) as { week_start?: unknown })?.week_start);
  } catch {
    week = null;
  }
  if (!allowed) return json({ error: "unauthorized" }, 401);

  const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
  const to = Deno.env.get("SCORECARD_TO") ?? "";
  const from = Deno.env.get("NOTIFY_EMAIL_FROM") || FROM;
  const appUrl = httpsUrl(Deno.env.get("APP_URL"), "https://app.activityplanet.app");
  const posthog = Deno.env.get("POSTHOG_URL");
  try {
    const result = await runScorecard(
      {
        rpc,
        resendKey,
        to,
        send: async (m) => (await sendResendEmails(resendKey, [m], fetch, from))[0],
        adminUrl: `${appUrl}/admin`,
        posthogUrl: posthog ? httpsUrl(posthog, "") || undefined : undefined,
      },
      week,
    );
    console.log("weekly-scorecard", result.status);
    return json(result);
  } catch (err) {
    console.error("weekly-scorecard: run failed", String(err).slice(0, 120));
    return json({ error: "run_failed" }, 500);
  }
});
