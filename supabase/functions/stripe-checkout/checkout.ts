// stripe-checkout logic (design section 9.3): a Checkout Session for a confirmed booking
// (destination charge with the application fee) and the outbound jobs the database queues
// (refunds, expiring an open checkout, closing a deleted coach's account). Pure: Stripe and the
// database come in as deps.
import { type Rpc, RpcError, type Stripe, stripeErrorName, UUID_RE } from "../_shared/stripe.ts";

export interface CheckoutDeps {
  stripe: Stripe;
  rpc: Rpc;
  appUrl: string;
  now?: () => Date;
}

export interface Answer {
  status: number;
  body: Record<string, unknown>;
}

interface CheckoutParams {
  booking_id: string;
  amount_minor: number;
  fee_minor: number;
  currency: string;
  stripe_account_id: string;
  title: string;
  pay_by: string;
  attempt: number;
}

/** Checkout expires at pay_by, kept inside Stripe's window (30 minutes to 24 hours from now). */
export function checkoutExpiresAt(payBy: string, now: Date): number {
  const min = Math.ceil(now.getTime() / 1000) + 31 * 60;
  const max = Math.floor(now.getTime() / 1000) + 23 * 3600 + 55 * 60;
  const want = Math.floor(new Date(payBy).getTime() / 1000);
  return Math.min(Math.max(Number.isFinite(want) ? want : min, min), max);
}

export async function createCheckout(
  userId: string,
  bookingId: unknown,
  deps: CheckoutDeps,
): Promise<Answer> {
  if (typeof bookingId !== "string" || !UUID_RE.test(bookingId)) {
    return { status: 400, body: { error: "invalid_booking" } };
  }
  let p: CheckoutParams;
  try {
    p = (await deps.rpc("booking_checkout_params", {
      p_booking: bookingId,
      p_user: userId,
    })) as CheckoutParams;
  } catch (err) {
    if (err instanceof RpcError && err.code === "not_payable")
      return { status: 409, body: { error: "not_payable" } };
    throw err;
  }
  const now = (deps.now ?? (() => new Date()))();
  const back = `${deps.appUrl}/bookings/${bookingId}`;
  const session = await deps.stripe.request(
    "POST",
    "/v1/checkout/sessions",
    {
      mode: "payment",
      line_items: [
        {
          quantity: 1,
          price_data: {
            currency: p.currency,
            unit_amount: p.amount_minor,
            product_data: { name: p.title },
          },
        },
      ],
      payment_intent_data: {
        application_fee_amount: p.fee_minor,
        transfer_data: { destination: p.stripe_account_id },
        metadata: { booking_id: bookingId },
      },
      client_reference_id: bookingId,
      metadata: { booking_id: bookingId },
      expires_at: checkoutExpiresAt(p.pay_by, now),
      success_url: `${back}?paid=1`,
      cancel_url: back,
    },
    `checkout:${bookingId}:${p.attempt}`,
  );
  if (!session.ok || typeof session.body.id !== "string" || typeof session.body.url !== "string") {
    return { status: 502, body: { error: "stripe_error", code: stripeErrorName(session) } };
  }
  await deps.rpc("booking_checkout_opened", {
    p_booking: bookingId,
    p_session_id: session.body.id,
    p_amount: p.amount_minor,
    p_fee: p.fee_minor,
    p_currency: p.currency,
    p_account: p.stripe_account_id,
  });
  return { status: 200, body: { url: session.body.url } };
}

export interface Job {
  id: number;
  op: "refund" | "expire_checkout" | "close_account";
  booking_id: string | null;
  amount_minor: number | null;
  idempotency_key: string;
  payment_intent_id: string | null;
  checkout_session_id: string | null;
  stripe_account_id: string | null;
}

export interface JobsSummary {
  claimed: number;
  done: number;
  failed: number;
}

async function runJob(job: Job, deps: CheckoutDeps): Promise<{ ok: boolean; error?: string }> {
  if (job.op === "refund") {
    if (!job.payment_intent_id || !job.amount_minor || job.amount_minor <= 0) {
      return { ok: false, error: "no_payment_intent" };
    }
    const res = await deps.stripe.request(
      "POST",
      "/v1/refunds",
      {
        payment_intent: job.payment_intent_id,
        amount: job.amount_minor,
        refund_application_fee: true,
        reverse_transfer: true,
        metadata: { booking_id: job.booking_id ?? undefined },
      },
      job.idempotency_key,
    );
    return res.ok ? { ok: true } : { ok: false, error: stripeErrorName(res) };
  }
  if (job.op === "expire_checkout") {
    if (!job.checkout_session_id) return { ok: true };
    const res = await deps.stripe.request(
      "POST",
      `/v1/checkout/sessions/${encodeURIComponent(job.checkout_session_id)}/expire`,
      {},
      job.idempotency_key,
    );
    // A session that already completed or expired has nothing left to expire.
    return res.ok || res.status === 400 ? { ok: true } : { ok: false, error: stripeErrorName(res) };
  }
  if (!job.stripe_account_id) return { ok: false, error: "no_account" };
  const res = await deps.stripe.request(
    "DELETE",
    `/v1/accounts/${encodeURIComponent(job.stripe_account_id)}`,
  );
  if (!res.ok && res.status !== 404) return { ok: false, error: stripeErrorName(res) };
  await deps.rpc("stripe_account_closed", { p_account: job.stripe_account_id });
  return { ok: true };
}

export async function runJobs(deps: CheckoutDeps, limit = 20): Promise<JobsSummary> {
  const jobs = ((await deps.rpc("stripe_jobs_claim", { p_limit: limit })) ?? []) as Job[];
  const summary: JobsSummary = { claimed: jobs.length, done: 0, failed: 0 };
  for (const job of jobs) {
    let result: { ok: boolean; error?: string };
    try {
      result = await runJob(job, deps);
    } catch {
      result = { ok: false, error: "exception" };
    }
    await deps.rpc("stripe_job_done", {
      p_id: job.id,
      p_ok: result.ok,
      p_error: result.error ?? null,
    });
    if (result.ok) summary.done += 1;
    else summary.failed += 1;
  }
  return summary;
}
