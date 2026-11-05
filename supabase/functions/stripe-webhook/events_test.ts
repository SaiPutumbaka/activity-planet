import { assertEquals } from "jsr:@std/assert@1.0.19";
import { keyGate, keyMode } from "../_shared/stripe.ts";
import { mockRpc } from "../_shared/testing.ts";
import { applyEvent, handleWebhook } from "./events.ts";
import { computeSignature } from "./signature.ts";

const SECRET = "whsec_test_secret";
const NOW = 1_800_000_000;
const BID = "22222222-2222-4222-8222-222222222222";

async function signed(event: Record<string, unknown>): Promise<[string, string]> {
  const body = JSON.stringify(event);
  return [body, `t=${NOW},v1=${await computeSignature(SECRET, NOW, body)}`];
}

function deps(answers: Record<string, unknown>) {
  const m = mockRpc({ stripe_event_begin: "new", stripe_event_finish: null, ...answers });
  const lines: string[] = [];
  return {
    m,
    lines,
    d: {
      rpc: m.rpc,
      secrets: [SECRET],
      keyMode: "test" as const,
      nowSeconds: () => NOW,
      log: (l: string) => lines.push(l),
    },
  };
}

Deno.test("key gate: payments_off without the secret key or the webhook secret", async () => {
  assertEquals(
    keyGate(
      (n) => (n === "STRIPE_SECRET_KEY" ? "sk_test_x" : undefined),
      ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"],
    )?.status,
    503,
  );
  const res = keyGate(() => undefined, ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"]);
  assertEquals((await res!.json()).error, "payments_off");
  assertEquals(
    keyGate(() => "x", ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"]),
    null,
  );
  assertEquals(keyMode("sk_live_abc"), "live");
  assertEquals(keyMode("rk_test_abc"), "test");
  assertEquals(keyMode("nope"), null);
});

Deno.test("a bad signature never reaches the database", async () => {
  const { m, d } = deps({});
  const [body] = await signed({ id: "evt_1", type: "charge.refunded" });
  const a = await handleWebhook(body, `t=${NOW},v1=${"0".repeat(64)}`, d);
  assertEquals(a, { status: 400, body: { error: "signature_mismatch" } });
  const stale = await handleWebhook(
    body,
    `t=${NOW - 400},v1=${await computeSignature(SECRET, NOW - 400, body)}`,
    d,
  );
  assertEquals(stale.body.error, "signature_stale");
  assertEquals(m.calls.length, 0);
});

Deno.test("paid checkout: begin, mark paid, finish", async () => {
  const { m, d, lines } = deps({ booking_mark_paid: "paid" });
  const [body, sig] = await signed({
    id: "evt_Paid1",
    type: "checkout.session.completed",
    livemode: false,
    data: {
      object: {
        id: "cs_1",
        payment_status: "paid",
        client_reference_id: BID,
        payment_intent: "pi_1",
        amount_total: 4000,
      },
    },
  });
  assertEquals(await handleWebhook(body, sig, d), { status: 200, body: { received: true } });
  assertEquals(
    m.calls.map((c) => c.name),
    ["stripe_event_begin", "booking_mark_paid", "stripe_event_finish"],
  );
  assertEquals(m.calls[0].args, {
    p_id: "evt_Paid1",
    p_type: "checkout.session.completed",
    p_account: null,
    p_object: "cs_1",
    p_livemode: false,
  });
  assertEquals(m.calls[1].args, {
    p_booking: BID,
    p_session_id: "cs_1",
    p_payment_intent: "pi_1",
    p_amount: 4000,
  });
  assertEquals(m.calls[2].args, { p_id: "evt_Paid1", p_error: null });
  assertEquals(lines.join(" ").includes("4000"), false);
});

Deno.test("a duplicate event answers 200 without handling it again", async () => {
  const { m, d } = deps({ stripe_event_begin: "done" });
  const [body, sig] = await signed({
    id: "evt_Dup1",
    type: "checkout.session.completed",
    data: { object: { id: "cs_1", payment_status: "paid" } },
  });
  assertEquals((await handleWebhook(body, sig, d)).body.duplicate, true);
  assertEquals(
    m.calls.map((c) => c.name),
    ["stripe_event_begin"],
  );
});

Deno.test("livemode mismatch is recorded and ignored", async () => {
  const { m, d } = deps({});
  const [body, sig] = await signed({
    id: "evt_Live1",
    type: "charge.refunded",
    livemode: true,
    data: { object: { payment_intent: "pi_1", amount_refunded: 1 } },
  });
  assertEquals((await handleWebhook(body, sig, d)).body.ignored, "livemode_mismatch");
  assertEquals(
    m.calls.map((c) => c.name),
    ["stripe_event_begin", "stripe_event_finish"],
  );
  assertEquals(m.calls[1].args.p_error, "livemode_mismatch");
});

Deno.test("a failing handler answers 500 (Stripe retries) and records the error", async () => {
  const m = mockRpc({ stripe_event_begin: "new", stripe_event_finish: null });
  const rpc = (name: string, args: Record<string, unknown>) =>
    name === "booking_refund_recorded"
      ? Promise.reject(new Error("rpc_booking_refund_recorded_500_error"))
      : m.rpc(name, args);
  const [body, sig] = await signed({
    id: "evt_Fail1",
    type: "charge.refunded",
    data: { object: { payment_intent: "pi_1", amount_refunded: 100 } },
  });
  const a = await handleWebhook(body, sig, {
    rpc,
    secrets: [SECRET],
    keyMode: "test",
    nowSeconds: () => NOW,
    log: () => {},
  });
  assertEquals(a.status, 500);
  assertEquals(m.calls.at(-1)?.args.p_error, "rpc_booking_refund_recorded_500_error");
});

Deno.test("handlers: the right RPC per event type", async () => {
  const cases: [Record<string, unknown>, string, Record<string, unknown> | null][] = [
    [
      { type: "checkout.session.expired", data: { object: { id: "cs_9" } } },
      "booking_payment_expired",
      { p_session_id: "cs_9" },
    ],
    [
      {
        type: "charge.refunded",
        data: { object: { payment_intent: "pi_2", amount_refunded: 2000 } },
      },
      "booking_refund_recorded",
      { p_payment_intent: "pi_2", p_refunded_minor: 2000 },
    ],
    [
      {
        type: "charge.dispute.created",
        data: { object: { payment_intent: "pi_3", status: "needs_response" } },
      },
      "booking_dispute_update",
      { p_payment_intent: "pi_3", p_status: "needs_response", p_closed: false },
    ],
    [
      {
        type: "charge.dispute.closed",
        data: { object: { payment_intent: "pi_3", status: "lost" } },
      },
      "booking_dispute_update",
      { p_payment_intent: "pi_3", p_status: "lost", p_closed: true },
    ],
    [
      { type: "account.application.deauthorized", account: "acct_5", data: { object: {} } },
      "stripe_account_sync",
      {
        p_account: "acct_5",
        p: { charges_enabled: false, payouts_enabled: false, disabled_reason: "deauthorized" },
      },
    ],
    [
      {
        type: "checkout.session.completed",
        data: { object: { id: "cs_1", payment_status: "unpaid" } },
      },
      "",
      null,
    ],
    [{ type: "customer.created", data: { object: { id: "cus_1" } } }, "", null],
  ];
  for (const [event, name, args] of cases) {
    const m = mockRpc({});
    await applyEvent(event, m.rpc);
    if (!name) {
      assertEquals(m.calls.length, 0, String(event.type));
    } else {
      assertEquals(m.calls[0].name, name);
      assertEquals(m.calls[0].args, args);
    }
  }
  const m = mockRpc({});
  await applyEvent(
    {
      type: "account.updated",
      data: {
        object: {
          id: "acct_6",
          charges_enabled: true,
          payouts_enabled: false,
          details_submitted: true,
          default_currency: "usd",
          requirements: { currently_due: ["external_account"], disabled_reason: null },
        },
      },
    },
    m.rpc,
  );
  assertEquals(m.calls[0].args, {
    p_account: "acct_6",
    p: {
      default_currency: "usd",
      charges_enabled: true,
      payouts_enabled: false,
      details_submitted: true,
      requirements_due: ["external_account"],
      disabled_reason: null,
    },
  });
});
