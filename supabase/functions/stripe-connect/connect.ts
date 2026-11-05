// stripe-connect logic (design section 9.2): Express onboarding, the dashboard link and an
// account refresh for the signed-in coach. Pure: Stripe and the database come in as deps.
import {
  type Params,
  PAYMENTS_OFF,
  type Rpc,
  type Stripe,
  stripeErrorName,
} from "../_shared/stripe.ts";

export interface ConnectDeps {
  stripe: Stripe;
  rpc: Rpc;
  appUrl: string;
}

export interface Answer {
  status: number;
  body: Record<string, unknown>;
}

interface ConnectContext {
  payments_enabled: boolean;
  is_coach: boolean;
  terms_ok: boolean;
  account_ok: boolean;
  email: string | null;
  account: { stripe_account_id: string; country: string } | null;
}

/** The fields the database keeps about a connected account: states and requirement keys only. */
export function accountFields(acct: Record<string, unknown>): Record<string, unknown> {
  const req = (acct.requirements ?? {}) as { currently_due?: unknown; disabled_reason?: unknown };
  const due = Array.isArray(req.currently_due)
    ? req.currently_due.filter((k): k is string => typeof k === "string").slice(0, 100)
    : [];
  return {
    stripe_account_id: acct.id,
    country: typeof acct.country === "string" ? acct.country.toUpperCase() : undefined,
    default_currency:
      typeof acct.default_currency === "string" ? acct.default_currency.toLowerCase() : undefined,
    charges_enabled: acct.charges_enabled === true,
    payouts_enabled: acct.payouts_enabled === true,
    details_submitted: acct.details_submitted === true,
    requirements_due: due,
    disabled_reason: typeof req.disabled_reason === "string" ? req.disabled_reason : null,
  };
}

export function accountParams(userId: string, country: string, email: string | null): Params {
  return {
    type: "express",
    country,
    email: email ?? undefined,
    business_type: "individual",
    capabilities: { card_payments: { requested: true }, transfers: { requested: true } },
    business_profile: { product_description: "Coaching sessions booked through Activity Planet" },
    settings: { payouts: { schedule: { delay_days: 7 } } },
    metadata: { coach_id: userId },
  };
}

export async function handleConnect(
  userId: string,
  body: unknown,
  deps: ConnectDeps,
): Promise<Answer> {
  const req = (body && typeof body === "object" ? body : {}) as { op?: unknown; country?: unknown };
  const op = req.op;
  if (op !== "onboard" && op !== "dashboard" && op !== "refresh") {
    return { status: 400, body: { error: "invalid_op" } };
  }
  const ctx = (await deps.rpc("stripe_connect_context", { p_user: userId })) as ConnectContext;
  if (!ctx?.payments_enabled) return { status: 503, body: { ...PAYMENTS_OFF } };
  if (!ctx.is_coach || !ctx.account_ok) return { status: 403, body: { error: "not_a_coach" } };

  if (op === "onboard") {
    if (!ctx.terms_ok) return { status: 403, body: { error: "coach_terms_required" } };
    let accountId = ctx.account?.stripe_account_id ?? null;
    if (!accountId) {
      const country = typeof req.country === "string" ? req.country.toUpperCase() : "";
      if (!/^[A-Z]{2}$/.test(country)) return { status: 400, body: { error: "invalid_country" } };
      const created = await deps.stripe.request(
        "POST",
        "/v1/accounts",
        accountParams(userId, country, ctx.email),
        `acct:${userId}`,
      );
      if (!created.ok || typeof created.body.id !== "string") {
        return { status: 502, body: { error: "stripe_error", code: stripeErrorName(created) } };
      }
      accountId = created.body.id;
      await deps.rpc("stripe_account_upsert", { p_coach: userId, p: accountFields(created.body) });
    }
    const link = await deps.stripe.request("POST", "/v1/account_links", {
      account: accountId,
      type: "account_onboarding",
      refresh_url: `${deps.appUrl}/coach/payouts?refresh=1`,
      return_url: `${deps.appUrl}/coach/payouts?return=1`,
    });
    if (!link.ok || typeof link.body.url !== "string") {
      return { status: 502, body: { error: "stripe_error", code: stripeErrorName(link) } };
    }
    return { status: 200, body: { url: link.body.url } };
  }

  const accountId = ctx.account?.stripe_account_id;
  if (!accountId) return { status: 409, body: { error: "no_account" } };

  if (op === "dashboard") {
    const link = await deps.stripe.request(
      "POST",
      `/v1/accounts/${encodeURIComponent(accountId)}/login_links`,
      {},
    );
    if (!link.ok || typeof link.body.url !== "string") {
      return { status: 502, body: { error: "stripe_error", code: stripeErrorName(link) } };
    }
    return { status: 200, body: { url: link.body.url } };
  }

  const acct = await deps.stripe.request("GET", `/v1/accounts/${encodeURIComponent(accountId)}`);
  if (!acct.ok)
    return { status: 502, body: { error: "stripe_error", code: stripeErrorName(acct) } };
  const fields = accountFields(acct.body);
  await deps.rpc("stripe_account_sync", { p_account: accountId, p: fields });
  return {
    status: 200,
    body: {
      charges_enabled: fields.charges_enabled,
      payouts_enabled: fields.payouts_enabled,
      details_submitted: fields.details_submitted,
      requirements_due: (fields.requirements_due as string[]).length,
    },
  };
}
