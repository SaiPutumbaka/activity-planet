// Resend sending for send-notifications (migrations 55 and 56). One POST /emails per message,
// each with Idempotency-Key "notification-<id>": a message whose answer was lost (timeout, 5xx,
// or the function dying before complete_notification_delivery) and is claimed again is not sent
// twice, since Resend answers a repeated key with the first result for 24 hours. One message per
// request also means one bad address fails only its own row, never the rest of the run.
// Resend's free tier is 100 emails a day (the database caps the worker at 90,
// claim_pending_notifications, meta notify_email_daily_cap) and 2 requests a second, so requests
// go one after another with a short pause.
import type { ChannelResult, EmailMessage } from "./worker.ts";

export const RESEND_EMAILS_URL = "https://api.resend.com/emails";
export const FROM = "Activity Planet <notifications@activityplanet.app>";
/** Between requests: under Resend's default 2 requests a second. */
export const PAUSE_MS = 550;

export type EmailResult = Exclude<ChannelResult, "skipped">;

export function emailBody(m: EmailMessage, from = FROM): unknown {
  return {
    from,
    to: [m.to],
    subject: m.subject,
    text: m.text,
    html: m.html,
    headers: m.headers,
  };
}

/** Stable per notification row, so a re-claimed row reuses its key. */
export function idempotencyKey(id: string): string {
  return `notification-${id}`;
}

async function errorName(res: Response): Promise<string> {
  const detail = await res.text().catch(() => "");
  try {
    return String((JSON.parse(detail) as { name?: unknown }).name ?? "").slice(0, 60);
  } catch {
    return "";
  }
}

/**
 * One result per message, in order: "sent" on 2xx; "retry" on 429, 5xx, network errors, a
 * concurrent request with the same key, and a refused API key (401, 403: configuration, not the
 * message; the rest of the run is not tried); "failed" on any other refusal of that one message.
 * A 409 invalid_idempotent_request means the key was already used for a message that went out,
 * so it counts as sent (never sent again).
 */
export async function sendResendEmails(
  apiKey: string,
  messages: EmailMessage[],
  fetchImpl: typeof fetch = fetch,
  from = FROM,
  sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
): Promise<EmailResult[]> {
  const out: EmailResult[] = [];
  let stop = false;
  for (const [i, m] of messages.entries()) {
    if (stop) {
      out.push("retry");
      continue;
    }
    if (i > 0) await sleep(PAUSE_MS);
    let res: Response;
    try {
      res = await fetchImpl(RESEND_EMAILS_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
          "Idempotency-Key": idempotencyKey(m.id),
        },
        body: JSON.stringify(emailBody(m, from)),
      });
    } catch {
      out.push("retry");
      continue;
    }
    if (res.ok) {
      await res.body?.cancel();
      out.push("sent");
      continue;
    }
    // The status and Resend's error name only; never the address.
    const name = await errorName(res);
    console.error(`send-notifications: resend refused an email: ${res.status} ${name}`);
    if (res.status === 409) {
      out.push(name === "invalid_idempotent_request" ? "sent" : "retry");
    } else if (res.status === 429 || res.status === 401 || res.status === 403) {
      out.push("retry");
      stop = true;
    } else if (res.status >= 500) {
      out.push("retry");
    } else {
      out.push("failed");
    }
  }
  return out;
}
