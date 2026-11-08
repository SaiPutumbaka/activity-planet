import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";
import {
  type ClaimedNotification,
  copyFor,
  escapeHtml,
  formatWhen,
  oneLine,
  pathFor,
  render,
} from "./templates.ts";

const links = { appUrl: "https://app.example.com", siteUrl: "https://example.com" };
const EVENT = "11111111-2222-4333-8444-555555555555";

function n(over: Partial<ClaimedNotification>): ClaimedNotification {
  return {
    id: "aaaaaaaa-2222-4333-8444-555555555555",
    kind: "rsvp_confirmed",
    event_id: EVENT,
    payload: {
      title: "Pickup run",
      starts_at: "2026-11-15T00:00:00Z",
      timezone: "America/Chicago",
      location_hint: "Riverside",
    },
    actor_name: null,
    hub: null,
    chapter: null,
    email: { to: "a@example.com", unsubscribe_token: "tok.en" },
    push: null,
    ...over,
  };
}

Deno.test("escapeHtml covers the five characters", () => {
  assertEquals(
    escapeHtml(`<a href="x">'&'</a>`),
    "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;",
  );
});

Deno.test("a host's message and a plan title are escaped in HTML, plain in text", () => {
  const r = render(
    n({
      kind: "broadcast",
      actor_name: "<b>Sam</b>",
      payload: {
        title: `Run <script>alert(1)</script>`,
        body: `Bring "water" & <img src=x onerror=alert(1)>`,
      },
    }),
    links,
  );
  assert(!r.html.includes("<script>"));
  assert(!r.html.includes("<img"));
  assert(!r.html.includes("<b>Sam"));
  assertStringIncludes(r.html, "&lt;script&gt;");
  assertStringIncludes(r.html, "&quot;water&quot; &amp; &lt;img");
  assertStringIncludes(r.text, `Bring "water" & <img src=x onerror=alert(1)>`);
  assertEquals(r.subject, "<b>Sam</b> about Run <script>alert(1)</script>");
});

Deno.test("subjects are one line (no header injection)", () => {
  const r = render(n({ payload: { title: "Run\r\nBcc: x@example.com" } }), links);
  assert(!/[\r\n]/.test(r.subject));
  assertEquals(oneLine("a\u0000b\n\nc"), "a b c");
});

Deno.test("List-Unsubscribe points at the one-click route; the footer links the page", () => {
  const r = render(n({}), links);
  assertEquals(r.headers["List-Unsubscribe"], "<https://example.com/api/unsubscribe?t=tok.en>");
  assertEquals(r.headers["List-Unsubscribe-Post"], "List-Unsubscribe=One-Click");
  assertStringIncludes(r.text, "https://example.com/unsubscribe?t=tok.en");
  assertStringIncludes(r.html, "https://example.com/unsubscribe?t=tok.en");
  assertStringIncludes(r.text, "https://app.example.com/you/notifications");
});

Deno.test("coarse location only, in the plan's timezone", () => {
  const c = copyFor(n({}));
  assertEquals(c.title, "You're going to Pickup run");
  assertEquals(c.body, "Sat, Nov 14, 6:00 PM · Riverside");
  assertEquals(formatWhen("2026-11-15T00:00:00Z", "Not/AZone"), "Sun, Nov 15, 12:00 AM UTC");
});

Deno.test("links stay inside the app", () => {
  assertEquals(pathFor(n({})), `/events/${EVENT}`);
  assertEquals(pathFor(n({ event_id: "../../x" })), "/inbox");
  assertEquals(
    pathFor(
      n({
        kind: "chapter_claim_update",
        event_id: null,
        payload: { status: "approved", chapter_slug: "run-club" },
      }),
    ),
    "/chapters/run-club",
  );
  assertEquals(render(n({}), links).push.url, `/events/${EVENT}`);
});

Deno.test("copy names no audience or city (D-040)", () => {
  const kinds = [
    "rsvp_confirmed",
    "attendee_joined",
    "waitlist_promoted",
    "rsvp_approved",
    "event_reminder_day",
    "event_reminder_2h",
    "event_cancelled",
    "event_updated",
    "checkin_prompt",
    "hub_new_event",
    "broadcast",
    "chapter_claim_update",
    "blocked_attendee",
    "message",
    "message_request",
    "booking_requested",
    "booking_confirmed",
    "booking_declined",
    "booking_cancelled",
    "booking_payment_due",
    "booking_reminder_day",
    "booking_reminder_2h",
    "booking_review_prompt",
    "booking_no_show",
    "review_received",
    "review_reply",
    "coach_payout_action",
  ];
  for (const kind of kinds) {
    const r = render(n({ kind, payload: {} }), links);
    assert(!/student|campus|atlanta|georgia|gsu/i.test(r.text), kind);
  }
});

Deno.test("chat notices name the sender or room, never the text, and open the chat", () => {
  const conv = "00000000-0000-4000-8000-000000000001";
  const dm = render(
    n({
      kind: "message",
      event_id: null,
      actor_name: "Sam",
      payload: { conversation_id: conv, count: 1, seq: 4 },
    }),
    links,
  );
  assertEquals(dm.subject, "New message from Sam");
  assertEquals(dm.push.url, `/chats/${conv}`);
  assertEquals(dm.push.tag, `message:${conv}`);
  const group = render(
    n({
      kind: "message",
      event_id: null,
      actor_name: "Sam",
      payload: { conversation_id: conv, count: 3, title: "Thursday climbers", body: "secret" },
    }),
    links,
  );
  assertEquals(group.subject, "3 new messages in Thursday climbers");
  assert(!group.text.includes("secret"));
  const req = render(
    n({ kind: "message_request", event_id: null, actor_name: null, payload: {} }),
    links,
  );
  assertEquals(req.push.url, "/chats?tab=requests");
});

Deno.test("booking notices open the booking, review notices the coach page, never the note", () => {
  const booking = "00000000-0000-4000-8000-0000000000b1";
  const base = { event_id: null, actor_name: "Sam" };
  const req = render(
    n({
      ...base,
      kind: "booking_requested",
      payload: {
        booking_id: booking,
        title: "Tennis, one hour",
        starts_at: "2027-01-09T15:00:00Z",
        timezone: "Europe/Berlin",
        client_note: "secret",
      },
    }),
    links,
  );
  assertEquals(req.subject, "Sam asked to book Tennis, one hour");
  assertStringIncludes(req.text, "Sat, Jan 9, 4:00 PM");
  assert(!req.text.includes("secret"));
  assertEquals(req.push.url, `/bookings/${booking}`);
  assertEquals(req.push.tag, `booking_requested:${booking}`);
  const taken = render(
    n({
      ...base,
      kind: "booking_declined",
      payload: { booking_id: booking, title: "Tennis", reason: "slot_taken" },
    }),
    links,
  );
  assertEquals(taken.subject, "That time was just taken");
  const cancelled = render(
    n({
      ...base,
      kind: "booking_cancelled",
      payload: { booking_id: booking, title: "Tennis", reason: "coach", refund_minor: 4000 },
    }),
    links,
  );
  assertEquals(cancelled.subject, "Tennis is cancelled");
  assertStringIncludes(cancelled.text, "The coach cancelled. A refund is on its way.");
  assert(!cancelled.subject.includes("40") && !cancelled.push.body.includes("40"));
  const fallback = render(
    n({
      ...base,
      kind: "booking_payment_due",
      payload: { booking_id: booking, title: "Tennis", fallback: "off_platform" },
    }),
    links,
  );
  assertStringIncludes(fallback.text, "Agree on how you'll pay before you meet.");
  const review = render(
    n({
      ...base,
      kind: "review_received",
      payload: { booking_id: booking, title: "Tennis", coach_handle: "sam_coach" },
    }),
    links,
  );
  assertEquals(review.push.url, "/coaches/sam_coach");
  const bad = render(
    n({ ...base, kind: "review_reply", payload: { coach_handle: "../x" } }),
    links,
  );
  assertEquals(bad.push.url, "/bookings");
  assertEquals(
    pathFor({ kind: "coach_payout_action", event_id: null, payload: {}, hub: null, chapter: null }),
    "/coach/payouts",
  );
  assertEquals(
    pathFor({
      kind: "coach_payout_action",
      event_id: null,
      payload: { reason: "dispute", booking_id: booking },
      hub: null,
      chapter: null,
    }),
    `/bookings/${booking}`,
  );
  assertEquals(
    pathFor({
      kind: "booking_confirmed",
      event_id: null,
      payload: { booking_id: "nope" },
      hub: null,
      chapter: null,
    }),
    "/bookings",
  );
});

// Migration 77 (launch audit H2, M13).
Deno.test("moderator alerts name the queue and open it", () => {
  const cs = n({
    kind: "report_new",
    event_id: null,
    payload: { priority: 0, due_at: "2026-11-15T04:00:00Z" },
  });
  assertEquals(copyFor(cs).title, "New child-safety report");
  assertStringIncludes(copyFor(cs).body ?? "", "4 hours");
  assertEquals(pathFor(cs), "/admin/reports");
  const td = n({ kind: "takedown_new", event_id: null, payload: { queue: "ncii", minor: true } });
  assertStringIncludes(copyFor(td).title, "may show a minor");
  assertEquals(pathFor(td), "/admin/takedowns");
  const due = n({
    kind: "moderation_due",
    event_id: null,
    payload: { reports_overdue: 2, takedowns_due: 1, images_waiting: 0 },
  });
  assertEquals(copyFor(due).body, "2 reports overdue. 1 takedowns due within 4 hours");
  assertEquals(pathFor(due), "/admin");
  const ops = n({ kind: "ops_alert", event_id: null, payload: { alert: "no_upcoming_events" } });
  assertStringIncludes(copyFor(ops).body ?? "", "no upcoming plans");
  assertEquals(pathFor(ops), "/admin/health");
});

Deno.test("the postal address joins the footer only when set", () => {
  const plain = render(n({}), links);
  assert(!plain.text.includes("Activity Planet, "));
  const withAddr = render(n({}), { ...links, postalAddress: "PO Box 1 <Atlanta>" });
  assertStringIncludes(withAddr.text, "Activity Planet, PO Box 1 <Atlanta>");
  assertStringIncludes(withAddr.html, "PO Box 1 &lt;Atlanta&gt;");
});
