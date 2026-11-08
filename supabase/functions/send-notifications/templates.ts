// Email and push copy for send-notifications (migration 55). The same wording as the inbox
// (apps/app/src/lib/notifications.ts notificationCopy), everyone-first (D-035, D-040: no
// audience assumed, no city assumed). Coarse location only (D-027): the plan's location_hint,
// never an address. Every value that came from a person (titles, names, a host's message) is
// escaped in HTML; the text part and push are plain text.

export interface ClaimedNotification {
  id: string;
  kind: string;
  created_at?: string;
  event_id: string | null;
  payload: Record<string, unknown>;
  actor_name: string | null;
  hub: { slug: string; name: string } | null;
  chapter: { slug: string; name: string } | null;
  email: { to: string; unsubscribe_token: string | null } | null;
  push: { device_id: string; endpoint: string; p256dh: string; auth: string }[] | null;
}

export interface Links {
  appUrl: string; // https://app.activityplanet.app
  siteUrl: string; // https://activityplanet.app
  /** Migration 77 (launch audit M13): the sender's postal address for the footer, from the
   * MAILING_ADDRESS secret; left out while it is unset. */
  postalAddress?: string;
}

export interface Rendered {
  subject: string;
  text: string;
  html: string;
  push: { title: string; body: string; url: string; tag: string };
  headers: Record<string, string>;
}

export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** Strips control characters and folds whitespace (subjects and push lines are one line). */
export function oneLine(value: string, max = 200): string {
  // deno-lint-ignore no-control-regex
  const s = value
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return s.length > max ? `${s.slice(0, max - 1).trimEnd()}…` : s;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() !== "" ? v : undefined;
}

function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

function validZone(tz: string | undefined): string | undefined {
  if (!tz) return undefined;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return tz;
  } catch {
    return undefined;
  }
}

/** "Sat, Nov 15, 7:00 PM" in the plan's own timezone (the UTC fallback names itself). */
export function formatWhen(
  startsAt: string | undefined,
  timezone: string | undefined,
): string | null {
  if (!startsAt) return null;
  const d = new Date(startsAt);
  if (Number.isNaN(d.getTime())) return null;
  const tz = validZone(timezone);
  const s = new Intl.DateTimeFormat("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZone: tz ?? "UTC",
    timeZoneName: tz ? undefined : "short",
  }).format(d);
  // ICU puts a narrow no-break space before AM/PM; plain spaces read the same in every client.
  return s.replace(/[\u00a0\u202f]/g, " ");
}

interface Copy {
  title: string;
  body: string | null;
}

export function copyFor(
  n: Pick<ClaimedNotification, "kind" | "payload" | "actor_name" | "hub" | "chapter">,
): Copy {
  const p = n.payload ?? {};
  const plan = str(p.title) ?? "a plan";
  const when = formatWhen(str(p.starts_at), str(p.timezone));
  const where = str(p.location_hint) ?? null;
  const whenWhere = [when, where].filter(Boolean).join(" · ") || null;
  const session = str(p.title) ?? "your session";
  switch (n.kind) {
    case "rsvp_confirmed":
      return p.status === "waitlisted"
        ? { title: `You're on the waitlist for ${plan}`, body: "We'll tell you if a spot opens." }
        : { title: `You're going to ${plan}`, body: whenWhere };
    case "attendee_joined": {
      const count = num(p.count) ?? 1;
      const who = n.actor_name ?? "Someone";
      const title =
        count <= 1
          ? `${who} joined ${plan}`
          : `${who} and ${count - 1} ${count - 1 === 1 ? "other" : "others"} joined ${plan}`;
      return { title, body: when };
    }
    case "waitlist_promoted":
      return { title: `A spot opened. You're going to ${plan}`, body: whenWhere };
    case "rsvp_approved":
      return { title: `You're approved for ${plan}`, body: "The address is on the plan now." };
    case "event_reminder_day":
      return { title: `Coming up: ${plan}`, body: whenWhere };
    case "event_reminder_2h":
      return { title: `${plan} starts soon`, body: whenWhere };
    case "event_cancelled": {
      const occ = num(p.occurrences);
      const dates = occ && occ > 1 ? ` (${occ} dates)` : "";
      const reason = str(p.reason);
      const why =
        reason === "host_deleted"
          ? "The host closed their account."
          : reason === "moderator_removed"
            ? "Our moderators took this plan down."
            : (reason ?? null);
      return { title: `${plan} is cancelled${dates}`, body: why ?? when };
    }
    case "event_updated": {
      const changed = Array.isArray(p.changed) ? p.changed : [];
      const time = changed.includes("time");
      const place = changed.includes("place");
      const what = time && place ? "a new time and place" : place ? "a new place" : "a new time";
      return { title: `${plan} has ${what}`, body: whenWhere };
    }
    case "checkin_prompt":
      return { title: `Did you go to ${plan}?`, body: "Tell us, and pick who you met there." };
    case "hub_new_event":
      return { title: n.hub ? `New in ${n.hub.name}: ${plan}` : `New plan: ${plan}`, body: when };
    case "broadcast":
      return {
        title: n.actor_name ? `${n.actor_name} about ${plan}` : `Message about ${plan}`,
        body: str(p.body) ?? null,
      };
    case "chapter_claim_update": {
      const name = n.chapter?.name ?? str(p.proposed_name) ?? "your chapter";
      if (p.status === "approved") {
        return { title: "Your chapter claim was approved", body: `You now organize ${name}.` };
      }
      const hubName = str(p.hub_name);
      return {
        title: "Your chapter claim wasn't approved",
        body: str(p.note) ?? (hubName ? `About ${name} in ${hubName}.` : `About ${name}.`),
      };
    }
    case "blocked_attendee":
      return {
        title: `Someone you blocked is on ${plan}`,
        body: "You won't see each other in the attendee list. Meet in a public place.",
      };
    // Migration 58: chat notices never carry the message text.
    case "message": {
      const count = num(p.count) ?? 1;
      const room = str(p.title);
      const who = n.actor_name ?? "someone";
      if (room) {
        return {
          title: count <= 1 ? `New message in ${room}` : `${count} new messages in ${room}`,
          body: null,
        };
      }
      return {
        title: count <= 1 ? `New message from ${who}` : `${count} new messages from ${who}`,
        body: null,
      };
    }
    case "message_request":
      return {
        title: n.actor_name ? `${n.actor_name} wants to message you` : "New message request",
        body: "Open Requests in Chats to accept or decline.",
      };
    // Migration 60: bookings. Never the client's note; no amounts in a push.
    case "booking_requested": {
      const who = n.actor_name ?? "Someone";
      return {
        title: `${who} asked to book ${session}`,
        body: when ? `${when}. Confirm or decline it.` : "Confirm or decline it.",
      };
    }
    case "booking_confirmed":
      return { title: `${session} is confirmed`, body: when };
    case "booking_declined": {
      const reason = str(p.reason);
      if (reason === "expired") {
        return {
          title: `Your request for ${session} expired`,
          body: "The coach didn't answer in time. Nothing was charged.",
        };
      }
      if (reason === "slot_taken")
        return { title: "That time was just taken", body: `Pick another time for ${session}.` };
      return { title: `Your request for ${session} wasn't accepted`, body: "Nothing was charged." };
    }
    case "booking_cancelled": {
      const reason = str(p.reason);
      const refund = (num(p.refund_minor) ?? 0) > 0 ? " A refund is on its way." : "";
      const why =
        reason === "coach"
          ? "The coach cancelled."
          : reason === "client"
            ? `${n.actor_name ?? "The client"} cancelled.`
            : reason === "account_deleted"
              ? "The other person closed their account."
              : reason === "unpaid"
                ? "It wasn't paid in time."
                : reason === "moderator" || reason === "banned" || reason === "listing_removed"
                  ? "Our moderators cancelled it."
                  : "It was cancelled.";
      return { title: `${session} is cancelled`, body: `${why}${refund}` };
    }
    case "booking_payment_due":
      return p.fallback === "off_platform"
        ? {
            title: `Arrange payment for ${session} directly`,
            body: "In-app payment isn't available for this booking. Agree on how you'll pay before you meet.",
          }
        : { title: `Pay for ${session}`, body: "Pay in the app to keep your booking." };
    case "booking_reminder_day":
      return { title: `Coming up: ${session}`, body: when };
    case "booking_reminder_2h":
      return { title: `${session} starts soon`, body: when };
    case "booking_review_prompt":
      return { title: `How was ${session}?`, body: "Leave a review for your coach." };
    case "booking_no_show":
      return p.party === "coach"
        ? {
            title: `${n.actor_name ?? "Your client"} reported that you missed ${session}`,
            body: "If you were there, you can contest it within 48 hours.",
          }
        : {
            title: `You were marked absent from ${session}`,
            body: "If you were there, you can contest it within 48 hours.",
          };
    case "review_received":
      return { title: "You have a new review", body: str(p.title) ?? null };
    case "review_reply":
      return { title: "Your coach replied to your review", body: str(p.title) ?? null };
    case "coach_payout_action":
      return p.reason === "dispute"
        ? {
            title: `A payment for ${session} is disputed`,
            body: "Our team reviews it. Open the booking for details.",
          }
        : { title: "Stripe needs a few details to pay you", body: "Open your payout settings." };
    // Migration 77: moderators only (counts, queue names and due times; never who or what).
    case "report_new": {
      const due = formatWhen(str(p.due_at), undefined);
      return num(p.priority) === 0
        ? {
            title: "New child-safety report",
            body: `Due within 4 hours${due ? ` (by ${due})` : ""}. Follow the NCMEC runbook.`,
          }
        : { title: "New report to review", body: "Open the report queue." };
    }
    case "takedown_new":
      if (p.queue === "listing_removal")
        return { title: "New listing removal request", body: "Open the takedown queue." };
      return {
        title:
          p.minor === true
            ? "New intimate-image takedown (may show a minor)"
            : "New intimate-image takedown",
        body:
          p.minor === true
            ? "Due within 4 hours. Remove first, then review."
            : "Due within 48 hours (Take It Down Act).",
      };
    case "moderation_due": {
      const parts = [
        [num(p.reports_overdue), "reports overdue"],
        [num(p.reports_due), "reports due within 4 hours"],
        [num(p.takedowns_overdue), "takedowns overdue"],
        [num(p.takedowns_due), "takedowns due within 4 hours"],
        [num(p.images_waiting), "chat photos waiting over 12 hours"],
        [num(p.deletions_stuck), "account deletions unfinished"],
        [num(p.listing_removals_waiting), "listing removals waiting over 3 days"],
      ]
        .filter(([n]) => typeof n === "number" && (n as number) > 0)
        .map(([n, label]) => `${n} ${label}`);
      return { title: "Moderation queue needs a look", body: parts.join(". ") || null };
    }
    case "ops_alert":
      return {
        title: "Activity Planet health alert",
        body: OPS_ALERTS[str(p.alert) ?? ""] ?? null,
      };
    default:
      return { title: "You have an update on Activity Planet", body: null };
  }
}

const OPS_ALERTS: Record<string, string> = {
  http_errors: "Server calls failed in the last day. Check the function logs.",
  cron_failures: "Scheduled jobs failed in the last day. Check cron.job_run_details.",
  no_upcoming_events: "There are no upcoming plans in the feed. Check the collector.",
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,80}$/;
const HANDLE_RE = /^[A-Za-z0-9_]{3,24}$/;

/** App path for a notification (same rules as notificationLink in the app). */
export function pathFor(
  n: Pick<ClaimedNotification, "kind" | "event_id" | "payload" | "hub" | "chapter">,
): string {
  if (n.kind === "message" || n.kind === "message_request") {
    const conv = str(n.payload?.conversation_id);
    if (n.kind === "message" && conv && UUID_RE.test(conv)) return `/chats/${conv}`;
    return n.kind === "message_request" ? "/chats?tab=requests" : "/chats";
  }
  // Migration 60: bookings and reviews.
  if (
    n.kind.startsWith("booking_") ||
    (n.kind === "coach_payout_action" && n.payload?.reason === "dispute")
  ) {
    const id = str(n.payload?.booking_id);
    return id && UUID_RE.test(id) ? `/bookings/${id}` : "/bookings";
  }
  if (n.kind === "review_received" || n.kind === "review_reply") {
    const handle = str(n.payload?.coach_handle);
    return handle && HANDLE_RE.test(handle) ? `/coaches/${handle}` : "/bookings";
  }
  if (n.kind === "coach_payout_action") return "/coach/payouts";
  // Migration 77: moderator alerts open their queue.
  if (n.kind === "report_new") return "/admin/reports";
  if (n.kind === "takedown_new") return "/admin/takedowns";
  if (n.kind === "moderation_due") return "/admin";
  if (n.kind === "ops_alert") return "/admin/health";
  if (n.kind === "chapter_claim_update") {
    const slug = n.chapter?.slug ?? str(n.payload?.chapter_slug);
    if (n.payload?.status === "approved" && slug && SLUG_RE.test(slug)) return `/chapters/${slug}`;
    if (n.hub && SLUG_RE.test(n.hub.slug)) return `/hubs/${n.hub.slug}`;
    return "/inbox";
  }
  if (n.event_id && UUID_RE.test(n.event_id)) return `/events/${n.event_id}`;
  if (n.chapter && SLUG_RE.test(n.chapter.slug)) return `/chapters/${n.chapter.slug}`;
  if (n.hub && SLUG_RE.test(n.hub.slug)) return `/hubs/${n.hub.slug}`;
  return "/inbox";
}

export function unsubscribeUrl(siteUrl: string, token: string): string {
  return `${siteUrl}/unsubscribe?t=${encodeURIComponent(token)}`;
}

export function unsubscribePostUrl(siteUrl: string, token: string): string {
  return `${siteUrl}/api/unsubscribe?t=${encodeURIComponent(token)}`;
}

/** One push per conversation on the lock screen: a newer one replaces the older. */
function chatTag(n: Pick<ClaimedNotification, "kind" | "payload">): string | null {
  if (n.kind !== "message" && n.kind !== "message_request") return null;
  const conv = str(n.payload?.conversation_id);
  return conv && UUID_RE.test(conv) ? `${n.kind}:${conv}`.slice(0, 64) : null;
}

/** One push per booking and kind on the lock screen. */
function bookingTag(n: Pick<ClaimedNotification, "kind" | "payload">): string | null {
  if (!n.kind.startsWith("booking_")) return null;
  const id = str(n.payload?.booking_id);
  return id && UUID_RE.test(id) ? `${n.kind}:${id}`.slice(0, 64) : null;
}

export function render(n: ClaimedNotification, links: Links): Rendered {
  const copy = copyFor(n);
  const title = oneLine(copy.title, 150);
  const body = copy.body ? copy.body.trim().slice(0, 1000) : null;
  const url = `${links.appUrl}${pathFor(n)}`;
  const settings = `${links.appUrl}/you/notifications`;
  const token = n.email?.unsubscribe_token ?? null;
  const unsub = token ? unsubscribeUrl(links.siteUrl, token) : settings;

  const text = [
    title,
    body ? `\n${body}` : "",
    `\nOpen it: ${url}`,
    "",
    "—",
    "You're getting this because of your Activity Planet notification settings.",
    `Change what you get: ${settings}`,
    `Stop these emails: ${unsub}`,
    links.postalAddress ? `Activity Planet, ${oneLine(links.postalAddress, 300)}` : "",
  ]
    .filter((l) => l !== "")
    .join("\n");

  const bodyHtml = body
    ? `<p style="margin:0 0 16px;white-space:pre-line">${escapeHtml(body)}</p>`
    : "";
  const html = `<!doctype html><html><body style="margin:0;padding:24px;background:#ffffff;color:#0e0f11;font-family:Figtree,-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5">
<p style="margin:0 0 12px;font-size:20px;font-weight:700">${escapeHtml(title)}</p>
${bodyHtml}<p style="margin:0 0 24px"><a href="${escapeHtml(url)}" style="display:inline-block;padding:10px 18px;border-radius:999px;background:#0e0f11;color:#ffffff;text-decoration:none;font-weight:600">Open in Activity Planet</a></p>
<p style="margin:0;color:#8a8f98;font-size:13px">You're getting this because of your Activity Planet notification settings. <a href="${escapeHtml(settings)}" style="color:#5b5f66">Change what you get</a> · <a href="${escapeHtml(unsub)}" style="color:#5b5f66">Unsubscribe from these emails</a></p>${
    links.postalAddress
      ? `\n<p style="margin:8px 0 0;color:#8a8f98;font-size:13px">Activity Planet, ${escapeHtml(oneLine(links.postalAddress, 300))}</p>`
      : ""
  }
</body></html>`;

  const headers: Record<string, string> = {};
  if (token) {
    headers["List-Unsubscribe"] = `<${unsubscribePostUrl(links.siteUrl, token)}>`;
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click";
  }

  return {
    subject: title,
    text,
    html,
    push: {
      title: oneLine(title, 120),
      body: body ? oneLine(body, 180) : "",
      url: pathFor(n),
      tag:
        chatTag(n) ?? bookingTag(n) ?? (n.event_id ? `${n.kind}:${n.event_id}`.slice(0, 64) : n.id),
    },
    headers,
  };
}
