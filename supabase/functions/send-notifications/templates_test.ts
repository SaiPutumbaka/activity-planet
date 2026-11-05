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
