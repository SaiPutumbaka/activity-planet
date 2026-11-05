// The delivery run of send-notifications (migration 55), with every outside call injected so
// it is tested with fakes (worker_test.ts).
//
//   1. claim_pending_notifications(50): due rows, already re-checked by the database (prefs,
//      quiet hours, blocks and mutes, stale plans, confirmed address, daily email cap).
//   2. Email through Resend, one request per message with the row id as its idempotency key
//      (migration 56), or skipped without RESEND_API_KEY. Push to every live device of the person, or skipped without the VAPID
//      keys. A push counts as sent when one device took it.
//   3. complete_notification_delivery(results, devices): sent / skipped / failed / retry per
//      channel; devices gone (404, 410) are revoked, failed ones counted.
//
// The answer (and the log) has counts only: no addresses, no endpoints, no copy.
import { type ClaimedNotification, type Links, render } from "./templates.ts";
import { classifyPushStatus, type PushOutcome } from "./webpush.ts";

export type ChannelResult = "sent" | "skipped" | "failed" | "retry";

export interface EmailMessage {
  /** The notification id (Resend idempotency key). */
  id: string;
  to: string;
  subject: string;
  text: string;
  html: string;
  headers: Record<string, string>;
}

export interface PushMessage {
  endpoint: string;
  p256dh: string;
  auth: string;
  payload: { title: string; body: string; url: string; tag: string; nid: string };
  ttl: number;
  urgency: "normal" | "high";
}

export interface WorkerDeps {
  rpc: (name: string, args: Record<string, unknown>) => Promise<unknown>;
  /** null when RESEND_API_KEY is not set. Resolves one "sent", "failed" (refused) or "retry" per message, in order. */
  sendEmails: ((messages: EmailMessage[]) => Promise<("sent" | "failed" | "retry")[]>) | null;
  /** null when the VAPID keys are not set. Resolves the push service's HTTP status. */
  sendPush: ((message: PushMessage) => Promise<number>) | null;
  links: Links;
}

export interface RunSummary {
  claimed: number;
  email: Record<ChannelResult, number>;
  push: Record<ChannelResult, number>;
  devices: { ok: number; gone: number; failed: number };
}

const BATCH = 50;

function zero(): Record<ChannelResult, number> {
  return { sent: 0, skipped: 0, failed: 0, retry: 0 };
}

/** Reminders say how soon; a push held longer than its moment is not worth delivering. */
function pushTiming(kind: string): { ttl: number; urgency: "normal" | "high" } {
  switch (kind) {
    case "event_reminder_2h":
      return { ttl: 2 * 3600, urgency: "high" };
    case "event_cancelled":
    case "event_updated":
    case "waitlist_promoted":
      return { ttl: 12 * 3600, urgency: "high" };
    default:
      return { ttl: 24 * 3600, urgency: "normal" };
  }
}

export function parseClaimed(raw: unknown): ClaimedNotification[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter(
    (r): r is ClaimedNotification =>
      !!r && typeof r === "object" && typeof (r as { id?: unknown }).id === "string",
  );
}

export async function runBatch(deps: WorkerDeps, limit = BATCH): Promise<RunSummary> {
  const claimed = parseClaimed(await deps.rpc("claim_pending_notifications", { p_limit: limit }));
  const summary: RunSummary = {
    claimed: claimed.length,
    email: zero(),
    push: zero(),
    devices: { ok: 0, gone: 0, failed: 0 },
  };
  if (claimed.length === 0) return summary;

  const results = new Map<
    string,
    { id: string; email?: ChannelResult; push?: ChannelResult; error?: string }
  >();
  const result = (id: string) => {
    let r = results.get(id);
    if (!r) {
      r = { id };
      results.set(id, r);
    }
    return r;
  };
  const devices = { ok: [] as string[], gone: [] as string[], failed: [] as string[] };

  const rendered = new Map(claimed.map((n) => [n.id, render(n, deps.links)]));

  // Email: one result per message (resend.ts sends them one at a time).
  const emailRows = claimed.filter((n) => n.email && n.email.to);
  if (emailRows.length > 0) {
    let outcomes: ChannelResult[];
    if (!deps.sendEmails) {
      outcomes = emailRows.map(() => "skipped");
    } else {
      try {
        const got = await deps.sendEmails(
          emailRows.map((n) => {
            const r = rendered.get(n.id)!;
            return {
              id: n.id,
              to: n.email!.to,
              subject: r.subject,
              text: r.text,
              html: r.html,
              headers: r.headers,
            };
          }),
        );
        outcomes = emailRows.map((_, i) => got[i] ?? "retry");
      } catch {
        outcomes = emailRows.map(() => "retry");
      }
    }
    emailRows.forEach((n, i) => {
      const outcome = outcomes[i];
      const r = result(n.id);
      r.email = outcome;
      if (outcome === "skipped") r.error = "no_resend_key";
      else if (outcome !== "sent") r.error = `email_${outcome}`;
      summary.email[outcome]++;
    });
  }

  // Push: every device, a few at a time.
  const pushRows = claimed.filter((n) => Array.isArray(n.push) && n.push.length > 0);
  for (const n of pushRows) {
    const r = result(n.id);
    if (!deps.sendPush) {
      r.push = "skipped";
      r.error = r.error ?? "no_vapid_keys";
      summary.push.skipped++;
      continue;
    }
    const out = rendered.get(n.id)!;
    const timing = pushTiming(n.kind);
    const outcomes: PushOutcome[] = await Promise.all(
      n.push!.map(async (d) => {
        let o: PushOutcome;
        try {
          o = classifyPushStatus(
            await deps.sendPush!({
              endpoint: d.endpoint,
              p256dh: d.p256dh,
              auth: d.auth,
              payload: { ...out.push, nid: n.id },
              ...timing,
            }),
          );
        } catch {
          o = "failed"; // bad keys or an endpoint refused before sending
        }
        if (o === "ok") devices.ok.push(d.device_id);
        else if (o === "gone") devices.gone.push(d.device_id);
        else if (o === "failed") devices.failed.push(d.device_id);
        return o;
      }),
    );
    let push: ChannelResult;
    if (outcomes.includes("ok")) push = "sent";
    else if (outcomes.includes("retry")) push = "retry";
    else if (outcomes.every((o) => o === "gone")) push = "skipped";
    else push = "failed";
    r.push = push;
    if (push !== "sent") r.error = r.error ?? `push_${push}`;
    summary.push[push]++;
  }

  summary.devices = {
    ok: devices.ok.length,
    gone: devices.gone.length,
    failed: devices.failed.length,
  };
  await deps.rpc("complete_notification_delivery", {
    p_results: [...results.values()],
    p_devices: devices,
  });
  return summary;
}

/** Up to `maxBatches` claims while each one comes back full. */
export async function runWorker(deps: WorkerDeps, maxBatches = 3): Promise<RunSummary> {
  const total: RunSummary = {
    claimed: 0,
    email: zero(),
    push: zero(),
    devices: { ok: 0, gone: 0, failed: 0 },
  };
  for (let i = 0; i < maxBatches; i++) {
    const s = await runBatch(deps);
    total.claimed += s.claimed;
    for (const k of Object.keys(s.email) as ChannelResult[]) {
      total.email[k] += s.email[k];
      total.push[k] += s.push[k];
    }
    total.devices.ok += s.devices.ok;
    total.devices.gone += s.devices.gone;
    total.devices.failed += s.devices.failed;
    if (s.claimed < BATCH) break;
  }
  return total;
}
