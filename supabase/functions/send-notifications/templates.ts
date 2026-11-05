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
    default:
      return { title: "You have an update on Activity Planet", body: null };
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,80}$/;

/** App path for a notification (same rules as notificationLink in the app). */
export function pathFor(
  n: Pick<ClaimedNotification, "kind" | "event_id" | "payload" | "hub" | "chapter">,
): string {
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
  ]
    .filter((l) => l !== "")
    .join("\n");

  const bodyHtml = body
    ? `<p style="margin:0 0 16px;white-space:pre-line">${escapeHtml(body)}</p>`
    : "";
  const html = `<!doctype html><html><body style="margin:0;padding:24px;background:#ffffff;color:#0e0f11;font-family:Figtree,-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5">
<p style="margin:0 0 12px;font-size:20px;font-weight:700">${escapeHtml(title)}</p>
${bodyHtml}<p style="margin:0 0 24px"><a href="${escapeHtml(url)}" style="display:inline-block;padding:10px 18px;border-radius:999px;background:#0e0f11;color:#ffffff;text-decoration:none;font-weight:600">Open in Activity Planet</a></p>
<p style="margin:0;color:#8a8f98;font-size:13px">You're getting this because of your Activity Planet notification settings. <a href="${escapeHtml(settings)}" style="color:#5b5f66">Change what you get</a> · <a href="${escapeHtml(unsub)}" style="color:#5b5f66">Unsubscribe from these emails</a></p>
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
      tag: n.event_id ? `${n.kind}:${n.event_id}`.slice(0, 64) : n.id,
    },
    headers,
  };
}
