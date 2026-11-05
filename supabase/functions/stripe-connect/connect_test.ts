import { assertEquals } from "jsr:@std/assert@1.0.19";
import { formEncode, keyGate, STRIPE_VERSION } from "../_shared/stripe.ts";
import { mockRpc, mockStripe } from "../_shared/testing.ts";
import { accountFields, handleConnect } from "./connect.ts";

const UID = "11111111-1111-4111-8111-111111111111";
const ctx = (over: Record<string, unknown> = {}) => ({
  payments_enabled: true,
  is_coach: true,
  terms_ok: true,
  account_ok: true,
  email: "coach@example.com",
  account: null,
  ...over,
});

Deno.test("key gate: payments_off without the secret key, before anything else", async () => {
  const res = keyGate(() => undefined, ["STRIPE_SECRET_KEY"]);
  assertEquals(res?.status, 503);
  assertEquals((await res!.json()).error, "payments_off");
  assertEquals(
    keyGate((n) => (n === "STRIPE_SECRET_KEY" ? "" : "x"), ["STRIPE_SECRET_KEY"])?.status,
    503,
  );
  assertEquals(
    keyGate(() => "sk_test_x", ["STRIPE_SECRET_KEY"]),
    null,
  );
});

Deno.test("form encoding: nested objects and arrays the way Stripe reads them", () => {
  assertEquals(
    formEncode({ a: 1, b: { c: "x y", d: [{ e: true }] }, skip: null, gone: undefined }),
    "a=1&b%5Bc%5D=x%20y&b%5Bd%5D%5B0%5D%5Be%5D=true",
  );
});

Deno.test("onboard creates the Express account once, then returns an account link", async () => {
  const { stripe, calls } = mockStripe((r) =>
    r.url.endsWith("/v1/accounts")
      ? {
          body: {
            id: "acct_New1",
            country: "US",
            charges_enabled: false,
            requirements: { currently_due: ["individual.dob.day"] },
          },
        }
      : { body: { url: "https://connect.stripe.com/setup/e/acct_New1/abc" } },
  );
  const { rpc, calls: rpcCalls } = mockRpc({ stripe_connect_context: ctx() });
  const a = await handleConnect(
    UID,
    { op: "onboard", country: "us" },
    { stripe, rpc, appUrl: "https://app.example.com" },
  );
  assertEquals(a.status, 200);
  assertEquals(a.body.url, "https://connect.stripe.com/setup/e/acct_New1/abc");
  assertEquals(calls.length, 2);
  const create = calls[0];
  assertEquals(create.method, "POST");
  assertEquals(create.headers["Idempotency-Key"], `acct:${UID}`);
  assertEquals(create.headers["Stripe-Version"], STRIPE_VERSION);
  assertEquals(create.headers.Authorization, "Bearer sk_test_mock");
  assertEquals(create.form.get("type"), "express");
  assertEquals(create.form.get("country"), "US");
  assertEquals(create.form.get("email"), "coach@example.com");
  assertEquals(create.form.get("business_type"), "individual");
  assertEquals(create.form.get("capabilities[card_payments][requested]"), "true");
  assertEquals(create.form.get("capabilities[transfers][requested]"), "true");
  assertEquals(create.form.get("settings[payouts][schedule][delay_days]"), "7");
  assertEquals(create.form.get("metadata[coach_id]"), UID);
  const link = calls[1];
  assertEquals(link.url, "https://api.stripe.com/v1/account_links");
  assertEquals(link.form.get("account"), "acct_New1");
  assertEquals(link.form.get("type"), "account_onboarding");
  assertEquals(link.form.get("return_url"), "https://app.example.com/coach/payouts?return=1");
  assertEquals(link.form.get("refresh_url"), "https://app.example.com/coach/payouts?refresh=1");
  const upsert = rpcCalls.find((c) => c.name === "stripe_account_upsert")!;
  assertEquals((upsert.args.p as Record<string, unknown>).requirements_due, ["individual.dob.day"]);
});

Deno.test("onboard with an account: only the link", async () => {
  const { stripe, calls } = mockStripe(() => ({ body: { url: "https://connect.stripe.com/x" } }));
  const { rpc } = mockRpc({
    stripe_connect_context: ctx({ account: { stripe_account_id: "acct_Old1", country: "DE" } }),
  });
  const a = await handleConnect(
    UID,
    { op: "onboard" },
    { stripe, rpc, appUrl: "https://app.example.com" },
  );
  assertEquals(a.status, 200);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].form.get("account"), "acct_Old1");
});

Deno.test("refusals: flag off, not a coach, terms, country, no account, bad op", async () => {
  const { stripe, calls } = mockStripe(() => ({ body: {} }));
  const deps = (c: Record<string, unknown>) => ({
    stripe,
    rpc: mockRpc({ stripe_connect_context: c }).rpc,
    appUrl: "https://a",
  });
  assertEquals(
    (
      await handleConnect(
        UID,
        { op: "onboard", country: "US" },
        deps(ctx({ payments_enabled: false })),
      )
    ).body.error,
    "payments_off",
  );
  assertEquals(
    (await handleConnect(UID, { op: "onboard", country: "US" }, deps(ctx({ is_coach: false }))))
      .status,
    403,
  );
  assertEquals(
    (await handleConnect(UID, { op: "onboard", country: "US" }, deps(ctx({ terms_ok: false }))))
      .body.error,
    "coach_terms_required",
  );
  assertEquals(
    (await handleConnect(UID, { op: "onboard", country: "USA" }, deps(ctx()))).body.error,
    "invalid_country",
  );
  assertEquals(
    (await handleConnect(UID, { op: "dashboard" }, deps(ctx()))).body.error,
    "no_account",
  );
  assertEquals((await handleConnect(UID, { op: "delete" }, deps(ctx()))).body.error, "invalid_op");
  assertEquals(calls.length, 0);
});

Deno.test("a Stripe error answers 502 with the code, never the message", async () => {
  const { stripe } = mockStripe(() => ({
    status: 400,
    body: { error: { code: "country_unsupported", message: "Sam in X" } },
  }));
  const { rpc } = mockRpc({ stripe_connect_context: ctx() });
  const a = await handleConnect(
    UID,
    { op: "onboard", country: "AQ" },
    { stripe, rpc, appUrl: "https://a" },
  );
  assertEquals(a.status, 502);
  assertEquals(a.body.code, "stripe_400_country_unsupported");
});

Deno.test("dashboard and refresh", async () => {
  const { stripe, calls } = mockStripe((r) =>
    r.url.endsWith("/login_links")
      ? { body: { url: "https://connect.stripe.com/express/x" } }
      : {
          body: {
            id: "acct_Old1",
            country: "de",
            default_currency: "EUR",
            charges_enabled: true,
            payouts_enabled: true,
            details_submitted: true,
            requirements: { currently_due: [], disabled_reason: null },
          },
        },
  );
  const { rpc, calls: rpcCalls } = mockRpc({
    stripe_connect_context: ctx({ account: { stripe_account_id: "acct_Old1", country: "DE" } }),
  });
  const deps = { stripe, rpc, appUrl: "https://a" };
  assertEquals(
    (await handleConnect(UID, { op: "dashboard" }, deps)).body.url,
    "https://connect.stripe.com/express/x",
  );
  assertEquals(calls[0].url, "https://api.stripe.com/v1/accounts/acct_Old1/login_links");
  const r = await handleConnect(UID, { op: "refresh" }, deps);
  assertEquals(r.body, {
    charges_enabled: true,
    payouts_enabled: true,
    details_submitted: true,
    requirements_due: 0,
  });
  assertEquals(calls[1].method, "GET");
  const sync = rpcCalls.find((c) => c.name === "stripe_account_sync")!;
  assertEquals(sync.args.p_account, "acct_Old1");
  assertEquals((sync.args.p as Record<string, unknown>).default_currency, "eur");
});

Deno.test("accountFields keeps requirement keys only", () => {
  const f = accountFields({
    id: "acct_1",
    requirements: { currently_due: ["a", 3, "b"] },
    charges_enabled: "yes",
  });
  assertEquals(f.requirements_due, ["a", "b"]);
  assertEquals(f.charges_enabled, false);
});
