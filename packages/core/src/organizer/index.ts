/**
 * Organizer claims and connected calendars (migration 62; COLLECTOR_COMPLETION 2.2 to 2.4), the
 * words and checks the app's /organizer pages use, pure so they can be tested without a browser.
 *
 *   claimMethodInfo("dns_txt")        // { label, summary }
 *   proofCopies(claim)                // what to copy for the claim's method: [{ label, value }]
 *   claimStatusLabel(claim)           // "Waiting for proof" | "Verified" | ...
 *   organizerErrorMessage(err)        // plain words for any start/check/connect/update error
 *   checkFeedUrl("webcal://...")      // { ok: true, url } | { ok: false, error }
 */

export const CLAIM_METHODS = ["meta", "well_known", "dns_txt", "feed"] as const;
export type ClaimMethod = (typeof CLAIM_METHODS)[number];
export type ClaimStatus = "pending" | "verified" | "failed" | "revoked";

export interface ClaimProofs {
  meta?: string;
  well_known?: { url: string; content: string };
  dns_txt?: { name: string; value: string };
  feed?: string;
}

/** One row of my_organizer_claims(). */
export interface OrganizerClaim {
  claim_id: string;
  status: ClaimStatus;
  method: ClaimMethod;
  host: string;
  feed_url: string | null;
  token: string | null;
  proofs: ClaimProofs | null;
  attempts: number;
  last_checked_at: string | null;
  verified_at: string | null;
  failure: string | null;
  created_at: string;
  source: { id: string; name: string; enabled: boolean; origin: string } | null;
  connected: {
    id: string;
    name: string;
    url: string;
    kind: string;
    enabled: boolean;
    stopped: boolean;
    last_ok_at: string | null;
    images_licensed: boolean | null;
  }[];
}

const METHOD_INFO: Record<ClaimMethod, { label: string; summary: string }> = {
  meta: {
    label: "A tag on your website",
    summary: "Add one line to the <head> of your site's home page or the calendar page.",
  },
  well_known: {
    label: "A file on your website",
    summary: "Upload a small text file to your site's /.well-known/ folder.",
  },
  dns_txt: {
    label: "A DNS record",
    summary: "Add a TXT record where you manage your domain. Checked right away.",
  },
  feed: {
    label: "Your calendar's description",
    summary:
      "Paste a code into your public calendar's description (works for Google Calendar, Outlook and other hosted calendars).",
  },
};

export function claimMethodInfo(method: ClaimMethod): { label: string; summary: string } {
  return METHOD_INFO[method];
}

/** What to copy for a pending claim, by its method. Empty once it is no longer pending. */
export function proofCopies(
  claim: Pick<OrganizerClaim, "method" | "token" | "proofs">,
): { label: string; value: string }[] {
  const p = claim.proofs;
  if (!p || !claim.token) return [];
  switch (claim.method) {
    case "meta":
      return p.meta ? [{ label: "Tag for the page's <head>", value: p.meta }] : [];
    case "well_known":
      return p.well_known
        ? [
            { label: "File address", value: p.well_known.url },
            { label: "File contents", value: p.well_known.content },
          ]
        : [];
    case "dns_txt":
      return p.dns_txt
        ? [
            { label: "Record name (host)", value: p.dns_txt.name },
            { label: "Record type", value: "TXT" },
            { label: "Record value", value: p.dns_txt.value },
          ]
        : [];
    case "feed":
      return [{ label: "Code for the calendar's description", value: claim.token }];
  }
}

const FAILURES: Record<string, string> = {
  token_not_found: "We read the page but didn't find the code.",
  dns_no_txt: "We didn't find the TXT record yet. DNS changes can take an hour.",
  expired: "It ran out of time (7 days or 10 checks). Start again when the proof is in place.",
  already_claimed: "Someone else already proved they run this source.",
  revoked: "A moderator withdrew this claim.",
  host_denied: "That site asked us not to collect from it, so the claim stopped.",
  feed_mismatch: "That calendar isn't the one this listing comes from.",
  fetch_failed: "We couldn't read the page.",
  "fetch_failed:robots_disallowed":
    "Your robots.txt keeps our bot out, so we can't read the page. Use the DNS record instead.",
};

/** Why a check missed, in plain words, or null. */
export function failureText(failure: string | null | undefined): string | null {
  if (!failure) return null;
  if (FAILURES[failure]) return FAILURES[failure]!;
  if (failure.startsWith("fetch_failed")) return FAILURES.fetch_failed!;
  return "The last check didn't find the proof.";
}

export function claimStatusLabel(claim: Pick<OrganizerClaim, "status">): string {
  switch (claim.status) {
    case "pending":
      return "Waiting for proof";
    case "verified":
      return "Verified";
    case "failed":
      return "Not verified";
    case "revoked":
      return "Withdrawn";
  }
}

export type FeedUrlCheck = { ok: true; url: string } | { ok: false; error: string };

/** The client-side check of a calendar link before connect_organizer_feed checks it again. */
export function checkFeedUrl(input: string): FeedUrlCheck {
  let t = input.trim();
  if (t === "") return { ok: false, error: "Paste your calendar's public link." };
  if (/^webcals?:\/\//i.test(t)) t = t.replace(/^webcals?:\/\//i, "https://");
  if (t.length > 500) return { ok: false, error: "That link is too long." };
  let u: URL;
  try {
    u = new URL(t);
  } catch {
    return { ok: false, error: "That doesn't look like a link." };
  }
  if (u.protocol !== "https:") return { ok: false, error: "Use the https:// or webcal:// link." };
  if (u.username || u.password) return { ok: false, error: "Use a link without a password." };
  return { ok: true, url: u.toString() };
}

const ERRORS: Record<string, string> = {
  not_authenticated: "Sign in again to continue.",
  forbidden: "Only the verified organizer can change this.",
  account_too_new: "Your account needs to be a day old before you can claim a listing.",
  rate_limited: "That's 5 claims today. Try again tomorrow.",
  invalid_method: "Choose how you'll prove it.",
  not_imported: "That isn't a listing we collected.",
  not_found: "We couldn't find that.",
  source_required: "Open the claim from the listing you organize.",
  invalid_host: "Choose your website's address.",
  host_mismatch: "That address doesn't match the listing's source.",
  host_denied: "We don't collect from that site.",
  feed_mismatch: "That calendar isn't the one this listing comes from.",
  feed_unavailable:
    "This listing doesn't come from a calendar feed. Choose another way to prove it.",
  already_claimed: "Someone else already proved they run this source. Ask us if that's wrong.",
  claim_not_verified: "Finish verifying the claim first.",
  feed_limit: "You can connect up to 3 calendars.",
  region_required: "Set where your events happen first.",
  region_unavailable: "We can't add a new area today. Try again tomorrow.",
  invalid_hub: "Choose a hub from the list.",
  invalid_event: "That item can't be changed any more.",
  not_connected: "Only calendars you connected can change this.",
  invalid_args: "Something in the change didn't come through. Try again.",
  url_invalid: "That doesn't look like a link.",
  url_not_https: "Use the https:// or webcal:// link.",
  url_has_credentials: "Use a link without a password.",
  url_port: "Use a link without a port number.",
  url_private_host: "Use a public link.",
  url_too_long: "That link is too long.",
  url_denylisted: "We don't collect from that site.",
  invalid_claim: "We couldn't find that claim.",
  invalid_state: "That sign-in link expired. Start again.",
  invalid_code: "Eventbrite didn't send a valid answer. Start again.",
  exchange_failed: "Eventbrite didn't accept the connection. Start again.",
};

export function organizerErrorCode(err: unknown): string {
  const m =
    typeof err === "object" &&
    err !== null &&
    typeof (err as { message?: unknown }).message === "string"
      ? (err as { message: string }).message.trim()
      : typeof err === "string"
        ? err.trim()
        : "";
  return /^[a-z0-9_]+$/.test(m) ? m : "";
}

export function organizerErrorMessage(err: unknown): string {
  return ERRORS[organizerErrorCode(err)] ?? "Something went wrong. Try again.";
}

/** Hosts a claim may name, the shortest (the registrable domain) first. */
export function sortHosts(hosts: readonly string[]): string[] {
  return [...new Set(hosts)].sort(
    (a, b) => a.split(".").length - b.split(".").length || a.localeCompare(b),
  );
}
