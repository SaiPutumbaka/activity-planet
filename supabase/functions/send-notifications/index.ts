// send-notifications: the email and push delivery worker (migration 55; PLAN.md 4.9, 4.10;
// the logic is in worker.ts, templates.ts, webpush.ts and resend.ts).
//
//   POST /send-notifications {}  -> claims due notifications, sends them, records the outcome.
//                                   Answers counts only.
//
// The caller is the database (pg_cron job send-notifications every 2 minutes, through pg_net and
// public.notify_worker_dispatch), not a user, so the gateway JWT check is off (config.toml).
// Every request must carry x-notify-secret, checked through notify_worker_verify_secret (vault
// secret notify_worker_secret, generated inside the database by migration 55).
//
// Optional project secrets (Supabase Edge Function secrets, never in a file):
//   RESEND_API_KEY                       without it every email is marked skipped
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY,
//   VAPID_SUBJECT (mailto: or https:)    without all three every push is marked skipped
//   APP_URL, SITE_URL                    links (default https://app.activityplanet.app and
//                                        https://activityplanet.app)
//   NOTIFY_EMAIL_FROM                    sender (default notifications@activityplanet.app)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by Supabase.
import { FROM, sendResendEmails } from "./resend.ts";
import { buildPushRequest, importVapidKeys, type VapidKeys } from "./webpush.ts";
import { runWorker, type WorkerDeps } from "./worker.ts";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function baseUrl(value: string | undefined, fallback: string): string {
  try {
    const u = new URL(value ?? fallback);
    return u.protocol === "https:" || u.hostname === "localhost" ? u.origin : fallback;
  } catch {
    return fallback;
  }
}

let vapidCache: Promise<VapidKeys | null> | null = null;

function loadVapid(): Promise<VapidKeys | null> {
  if (!vapidCache) {
    const pub = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
    const priv = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
    const subject = Deno.env.get("VAPID_SUBJECT") ?? "";
    vapidCache =
      pub && priv && subject
        ? importVapidKeys(pub, priv, subject).catch(() => {
            console.error("send-notifications: VAPID keys could not be read; push is skipped");
            return null;
          })
        : Promise.resolve(null);
  }
  return vapidCache;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "not_found" }, 404);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ error: "misconfigured" }, 500);
  const auth = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` };

  const rpc = async (name: string, args: Record<string, unknown>) => {
    const res = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify(args),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`rpc_${name}_http_${res.status}`);
    return text ? JSON.parse(text) : null;
  };

  const secret = req.headers.get("x-notify-secret") ?? "";
  let allowed = false;
  try {
    allowed =
      secret.length >= 32 &&
      (await rpc("notify_worker_verify_secret", { p_secret: secret })) === true;
  } catch (err) {
    console.error("send-notifications: secret check failed", String(err));
    return json({ error: "secret_check_failed" }, 500);
  }
  await req.body?.cancel();
  if (!allowed) return json({ error: "unauthorized" }, 401);

  const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
  const from = Deno.env.get("NOTIFY_EMAIL_FROM") || FROM;
  const vapid = await loadVapid();

  const deps: WorkerDeps = {
    rpc,
    sendEmails: resendKey ? (messages) => sendResendEmails(resendKey, messages, fetch, from) : null,
    sendPush: vapid
      ? async (m) => {
          const { url, init } = await buildPushRequest(
            { endpoint: m.endpoint, p256dh: m.p256dh, auth: m.auth },
            m.payload,
            vapid,
            { ttl: m.ttl, urgency: m.urgency },
          );
          const res = await fetch(url, init);
          await res.body?.cancel();
          return res.status;
        }
      : null,
    links: {
      appUrl: baseUrl(Deno.env.get("APP_URL"), "https://app.activityplanet.app"),
      siteUrl: baseUrl(Deno.env.get("SITE_URL"), "https://activityplanet.app"),
      // Launch audit M13: the postal address for the email footer, once Sai has one.
      postalAddress: Deno.env.get("MAILING_ADDRESS")?.trim() || undefined,
    },
  };

  try {
    const summary = await runWorker(deps);
    console.log("send-notifications", JSON.stringify(summary));
    return json({
      ...summary,
      email_configured: Boolean(resendKey),
      push_configured: Boolean(vapid),
    });
  } catch (err) {
    console.error("send-notifications: run failed", String(err).slice(0, 200));
    return json({ error: "run_failed" }, 500);
  }
});
