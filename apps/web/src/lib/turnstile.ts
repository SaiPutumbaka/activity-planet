import { hostsOf, verifyTurnstile } from "@ap/core/turnstile";

import { siteUrl } from "@/lib/site";

/**
 * The hosts a Turnstile answer may name for this deployment: the site URL, every host Vercel
 * says this deployment is served on (its own URL, its branch URL and the production domain), the
 * host the request itself came in on (Vercel routes by Host, so it is always one of this
 * project's domains, including a second production domain or a preview), and any extra hosts in
 * TURNSTILE_HOSTNAMES (comma separated). A token solved on another site is still refused.
 */
export function turnstileHosts(request: Request): string[] {
  let requestHost: string | null = null;
  try {
    requestHost = new URL(request.url).host;
  } catch {
    requestHost = null;
  }
  return hostsOf(
    siteUrl(),
    process.env.VERCEL_URL,
    process.env.VERCEL_BRANCH_URL,
    process.env.VERCEL_PROJECT_PRODUCTION_URL,
    requestHost,
    process.env.TURNSTILE_HOSTNAMES,
  );
}

/** Turnstile for the public forms (launch audit L9: fails closed in production without its
 * secret, and checks the answer's hostname). */
export function turnstileFor(request: Request, token: unknown, ip: string | null) {
  return verifyTurnstile(token, ip, {
    secret: process.env.TURNSTILE_SECRET_KEY,
    vercelEnv: process.env.VERCEL_ENV,
    hostnames: turnstileHosts(request),
  });
}
