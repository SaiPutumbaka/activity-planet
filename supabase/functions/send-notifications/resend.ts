// Resend batch sending for send-notifications (migration 55). One POST /emails/batch per run
// (up to 100 messages). Resend's free tier is 100 emails a day; the database caps the worker
// at 90 (claim_pending_notifications, meta notify_email_daily_cap).
import type { EmailMessage } from "./worker.ts";

export const RESEND_BATCH_URL = "https://api.resend.com/emails/batch";
export const FROM = "Activity Planet <notifications@activityplanet.app>";

export function batchBody(messages: EmailMessage[], from = FROM): unknown[] {
  return messages.map((m) => ({
    from,
    to: [m.to],
    subject: m.subject,
    text: m.text,
    html: m.html,
    headers: m.headers,
  }));
}

/** "sent" on 2xx, "retry" on 429 and 5xx (and network errors), "failed" on any other refusal. */
export async function sendResendBatch(
  apiKey: string,
  messages: EmailMessage[],
  fetchImpl: typeof fetch = fetch,
  from = FROM,
): Promise<"sent" | "failed" | "retry"> {
  if (messages.length === 0) return "sent";
  let res: Response;
  try {
    res = await fetchImpl(RESEND_BATCH_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(batchBody(messages, from)),
    });
  } catch {
    return "retry";
  }
  const detail = await res.text().catch(() => "");
  if (res.ok) return "sent";
  // The status and Resend's error name only; never the addresses.
  let name = "";
  try {
    name = String((JSON.parse(detail) as { name?: unknown }).name ?? "");
  } catch {
    /* not JSON */
  }
  console.error(`send-notifications: resend refused the batch: ${res.status} ${name.slice(0, 60)}`);
  return res.status === 429 || res.status >= 500 ? "retry" : "failed";
}
