import { assertEquals } from "jsr:@std/assert@1.0.19";
import { keyGate, RpcError } from "../_shared/stripe.ts";
import { mockRpc, mockStripe } from "../_shared/testing.ts";
import { checkoutExpiresAt, createCheckout, runJobs } from "./checkout.ts";

const UID = "11111111-1111-4111-8111-111111111111";
const BID = "22222222-2222-4222-8222-222222222222";
const NOW = new Date("2027-01-01T12:00:00Z");
const params = {
  booking_id: BID,
  amount_minor: 4000,
  fee_minor: 480,
  currency: "usd",
  stripe_account_id: "acct_Coach1",
  title: "Tennis, one hour",
  pay_by: "2027-01-02T08:00:00Z",
  attempt: 2,
};

Deno.test("key gate: payments_off without the secret key", async () => {
  const res = keyGate(() => undefined, ["STRIPE_SECRET_KEY"]);
  assertEquals(res?.status, 503);
  assertEquals((await res!.json()).error, "payments_off");
});

Deno.test("create: one destination charge with the application fee", async () => {
  const { stripe, calls } = mockStripe(() => ({
    body: { id: "cs_test_1", url: "https://checkout.stripe.com/c/pay/cs_test_1" },
  }));
  const { rpc, calls: rpcCalls } = mockRpc({
    booking_checkout_params: params,
    booking_checkout_opened: {},
  });
  const a = await createCheckout(UID, BID, {
    stripe,
    rpc,
    appUrl: "https://app.example.com",
    now: () => NOW,
  });
  assertEquals(a, { status: 200, body: { url: "https://checkout.stripe.com/c/pay/cs_test_1" } });
  assertEquals(rpcCalls[0], {
    name: "booking_checkout_params",
    args: { p_booking: BID, p_user: UID },
  });
  const f = calls[0].form;
  assertEquals(calls[0].url, "https://api.stripe.com/v1/checkout/sessions");
  assertEquals(calls[0].headers["Idempotency-Key"], `checkout:${BID}:2`);
  assertEquals(f.get("mode"), "payment");
  assertEquals(f.get("line_items[0][quantity]"), "1");
  assertEquals(f.get("line_items[0][price_data][currency]"), "usd");
  assertEquals(f.get("line_items[0][price_data][unit_amount]"), "4000");
  assertEquals(f.get("line_items[0][price_data][product_data][name]"), "Tennis, one hour");
  assertEquals(f.get("payment_intent_data[application_fee_amount]"), "480");
  assertEquals(f.get("payment_intent_data[transfer_data][destination]"), "acct_Coach1");
  assertEquals(f.get("payment_intent_data[metadata][booking_id]"), BID);
  assertEquals(f.get("client_reference_id"), BID);
  assertEquals(f.get("expires_at"), String(Date.parse("2027-01-02T08:00:00Z") / 1000));
  assertEquals(f.get("success_url"), `https://app.example.com/bookings/${BID}?paid=1`);
  assertEquals(f.get("cancel_url"), `https://app.example.com/bookings/${BID}`);
  assertEquals(rpcCalls[1].name, "booking_checkout_opened");
  assertEquals(rpcCalls[1].args.p_session_id, "cs_test_1");
});

Deno.test("checkout expiry stays inside Stripe's 30 minutes to 24 hours", () => {
  const n = NOW.getTime() / 1000;
  assertEquals(checkoutExpiresAt("2027-01-01T12:05:00Z", NOW), n + 31 * 60);
  assertEquals(checkoutExpiresAt("2027-01-05T12:00:00Z", NOW), n + 23 * 3600 + 55 * 60);
  assertEquals(checkoutExpiresAt("2027-01-01T18:00:00Z", NOW), n + 6 * 3600);
});

Deno.test("create refusals: bad id, not payable, Stripe error", async () => {
  const { stripe, calls } = mockStripe(() => ({
    status: 402,
    body: { error: { type: "card_error" } },
  }));
  const notPayable = mockRpc({
    booking_checkout_params: new RpcError("booking_checkout_params", 400, "not_payable"),
  });
  assertEquals(
    (await createCheckout(UID, "nope", { stripe, rpc: notPayable.rpc, appUrl: "https://a" })).body
      .error,
    "invalid_booking",
  );
  assertEquals(
    await createCheckout(UID, BID, { stripe, rpc: notPayable.rpc, appUrl: "https://a" }),
    { status: 409, body: { error: "not_payable" } },
  );
  assertEquals(calls.length, 0);
  const ok = mockRpc({ booking_checkout_params: params });
  const a = await createCheckout(UID, BID, {
    stripe,
    rpc: ok.rpc,
    appUrl: "https://a",
    now: () => NOW,
  });
  assertEquals(a.status, 502);
  assertEquals(a.body.code, "stripe_402_card_error");
  assertEquals(
    ok.calls.some((c) => c.name === "booking_checkout_opened"),
    false,
  );
});

Deno.test(
  "jobs: refund with the fee back and the transfer reversed, expire, close; outcomes recorded",
  async () => {
    const { stripe, calls } = mockStripe((r) =>
      r.url.includes("/expire")
        ? { status: 400, body: { error: { code: "checkout_session_expired" } } }
        : { body: { id: "re_1" } },
    );
    const jobs = [
      {
        id: 1,
        op: "refund",
        booking_id: BID,
        amount_minor: 2000,
        idempotency_key: `refund:${BID}:cancel`,
        payment_intent_id: "pi_1",
        checkout_session_id: "cs_1",
        stripe_account_id: "acct_1",
      },
      {
        id: 2,
        op: "expire_checkout",
        booking_id: BID,
        amount_minor: null,
        idempotency_key: "expire:cs_2",
        payment_intent_id: null,
        checkout_session_id: "cs_2",
        stripe_account_id: "acct_1",
      },
      {
        id: 3,
        op: "close_account",
        booking_id: null,
        amount_minor: null,
        idempotency_key: "close:acct_9",
        payment_intent_id: null,
        checkout_session_id: null,
        stripe_account_id: "acct_9",
      },
      {
        id: 4,
        op: "refund",
        booking_id: BID,
        amount_minor: 100,
        idempotency_key: "refund:x",
        payment_intent_id: null,
        checkout_session_id: null,
        stripe_account_id: null,
      },
    ];
    const { rpc, calls: rpcCalls } = mockRpc({ stripe_jobs_claim: jobs });
    const s = await runJobs({ stripe, rpc, appUrl: "https://a" });
    assertEquals(s, { claimed: 4, done: 3, failed: 1 });
    const refund = calls[0];
    assertEquals(refund.url, "https://api.stripe.com/v1/refunds");
    assertEquals(refund.headers["Idempotency-Key"], `refund:${BID}:cancel`);
    assertEquals(refund.form.get("payment_intent"), "pi_1");
    assertEquals(refund.form.get("amount"), "2000");
    assertEquals(refund.form.get("refund_application_fee"), "true");
    assertEquals(refund.form.get("reverse_transfer"), "true");
    assertEquals(calls[1].url, "https://api.stripe.com/v1/checkout/sessions/cs_2/expire");
    assertEquals(calls[2].method, "DELETE");
    assertEquals(calls[2].url, "https://api.stripe.com/v1/accounts/acct_9");
    assertEquals(calls.length, 3);
    const done = rpcCalls
      .filter((c) => c.name === "stripe_job_done")
      .map((c) => [c.args.p_id, c.args.p_ok, c.args.p_error]);
    assertEquals(done, [
      [1, true, null],
      [2, true, null],
      [3, true, null],
      [4, false, "no_payment_intent"],
    ]);
    assertEquals(
      rpcCalls.some((c) => c.name === "stripe_account_closed" && c.args.p_account === "acct_9"),
      true,
    );
  },
);

Deno.test(
  "a failed refund is retried later (stripe_job_done false with the error name)",
  async () => {
    const { stripe } = mockStripe(() => ({
      status: 500,
      body: { error: { type: "api_error", message: "x" } },
    }));
    const { rpc, calls } = mockRpc({
      stripe_jobs_claim: [
        {
          id: 7,
          op: "refund",
          booking_id: BID,
          amount_minor: 4000,
          idempotency_key: "k",
          payment_intent_id: "pi_7",
          checkout_session_id: null,
          stripe_account_id: null,
        },
      ],
    });
    assertEquals(await runJobs({ stripe, rpc, appUrl: "https://a" }), {
      claimed: 1,
      done: 0,
      failed: 1,
    });
    const done = calls.find((c) => c.name === "stripe_job_done")!;
    assertEquals(done.args, { p_id: 7, p_ok: false, p_error: "stripe_500_api_error" });
  },
);
