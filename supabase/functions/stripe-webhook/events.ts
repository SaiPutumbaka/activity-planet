// stripe-webhook event handling (design section 9.4). Idempotent: stripe_event_begin records each
// event id once and a processed event answers 200 at once; every handler is itself idempotent, so
// a replay is harmless. Logs carry event ids and types only.
import { type Rpc, UUID_RE } from "../_shared/stripe.ts";
import { verifyStripeSignature } from "./signature.ts";

export interface WebhookDeps {
  rpc: Rpc;
  secrets: string[];
  keyMode: "live" | "test" | null;
  nowSeconds: () => number;
  log?: (line: string) => void;
}

export interface Answer {
  status: number;
  body: Record<string, unknown>;
}

interface StripeEvent {
  id?: unknown;
  type?: unknown;
  account?: unknown;
  livemode?: unknown;
  data?: { object?: Record<string, unknown> };
}

const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const int = (v: unknown): number | null =>
  typeof v === "number" && Number.isInteger(v) ? v : null;

/** The handler for one event type, or null when the type is only recorded. */
export async function applyEvent(event: StripeEvent, rpc: Rpc): Promise<string> {
  const type = String(event.type);
  const obj = event.data?.object ?? {};
  switch (type) {
    case "account.updated": {
      const acct = str(obj.id);
      if (!acct) return "ignored";
      const req = (obj.requirements ?? {}) as {
        currently_due?: unknown;
        disabled_reason?: unknown;
      };
      await rpc("stripe_account_sync", {
        p_account: acct,
        p: {
          default_currency: str(obj.default_currency) ?? undefined,
          charges_enabled: obj.charges_enabled === true,
          payouts_enabled: obj.payouts_enabled === true,
          details_submitted: obj.details_submitted === true,
          requirements_due: Array.isArray(req.currently_due)
            ? req.currently_due.filter((k) => typeof k === "string").slice(0, 100)
            : [],
          disabled_reason: str(req.disabled_reason),
        },
      });
      return "account_synced";
    }
    case "account.application.deauthorized": {
      const acct = str(event.account);
      if (!acct) return "ignored";
      await rpc("stripe_account_sync", {
        p_account: acct,
        p: { charges_enabled: false, payouts_enabled: false, disabled_reason: "deauthorized" },
      });
      return "account_deauthorized";
    }
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      if (obj.payment_status !== "paid") return "not_paid";
      const meta = (obj.metadata ?? {}) as Record<string, unknown>;
      const booking = str(obj.client_reference_id) ?? str(meta.booking_id);
      const result = await rpc("booking_mark_paid", {
        p_booking: booking && UUID_RE.test(booking) ? booking : null,
        p_session_id: str(obj.id),
        p_payment_intent: str(obj.payment_intent),
        p_amount: int(obj.amount_total),
      });
      return `paid:${String(result)}`;
    }
    case "checkout.session.expired": {
      const id = str(obj.id);
      if (!id) return "ignored";
      return `expired:${String(await rpc("booking_payment_expired", { p_session_id: id }))}`;
    }
    case "charge.refunded": {
      const pi = str(obj.payment_intent);
      const refunded = int(obj.amount_refunded);
      if (!pi || refunded === null) return "ignored";
      return `refund:${String(await rpc("booking_refund_recorded", { p_payment_intent: pi, p_refunded_minor: refunded }))}`;
    }
    case "refund.updated":
      // The total arrives with charge.refunded; a failed refund is retried by its job.
      return obj.status === "failed" ? "refund_failed" : "recorded";
    case "charge.dispute.created":
    case "charge.dispute.closed": {
      const pi = str(obj.payment_intent);
      if (!pi) return "ignored";
      const result = await rpc("booking_dispute_update", {
        p_payment_intent: pi,
        p_status: str(obj.status) ?? "unknown",
        p_closed: type === "charge.dispute.closed",
      });
      return `dispute:${String(result)}`;
    }
    default:
      return "recorded";
  }
}

export async function handleWebhook(
  payload: string,
  signature: string | null,
  deps: WebhookDeps,
): Promise<Answer> {
  const log = deps.log ?? ((line: string) => console.log(line));
  const check = await verifyStripeSignature(payload, signature, deps.secrets, deps.nowSeconds());
  if (check !== "ok") return { status: 400, body: { error: `signature_${check}` } };

  let event: StripeEvent;
  try {
    event = JSON.parse(payload) as StripeEvent;
  } catch {
    return { status: 400, body: { error: "invalid_json" } };
  }
  const id = str(event.id);
  const type = str(event.type);
  if (!id || !/^evt_[A-Za-z0-9]+$/.test(id) || !type)
    return { status: 400, body: { error: "invalid_event" } };
  const obj = event.data?.object ?? {};

  const begun = await deps.rpc("stripe_event_begin", {
    p_id: id,
    p_type: type,
    p_account: str(event.account),
    p_object: str(obj.id),
    p_livemode: event.livemode === true,
  });
  if (begun === "done") {
    log(`stripe-webhook ${id} ${type} duplicate`);
    return { status: 200, body: { received: true, duplicate: true } };
  }
  // An event from the other mode than the key (test events on a live project, or the reverse)
  // is recorded and ignored.
  if (deps.keyMode && (event.livemode === true) !== (deps.keyMode === "live")) {
    await deps.rpc("stripe_event_finish", { p_id: id, p_error: "livemode_mismatch" });
    log(`stripe-webhook ${id} ${type} livemode_mismatch`);
    return { status: 200, body: { received: true, ignored: "livemode_mismatch" } };
  }
  try {
    const outcome = await applyEvent(event, deps.rpc);
    await deps.rpc("stripe_event_finish", { p_id: id, p_error: null });
    log(`stripe-webhook ${id} ${type} ${outcome}`);
    return { status: 200, body: { received: true } };
  } catch (err) {
    const name = err instanceof Error ? err.message.slice(0, 120) : "error";
    await deps.rpc("stripe_event_finish", { p_id: id, p_error: name }).catch(() => null);
    log(`stripe-webhook ${id} ${type} failed`);
    // Stripe retries a non-2xx answer; the ledger makes the retry safe.
    return { status: 500, body: { error: "handler_failed" } };
  }
}
