import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

const {
  badgeLabel,
  broadcastErrorMessage,
  broadcastOpen,
  broadcastSentMessage,
  fromTimeInput,
  groupNotifications,
  notificationCopy,
  notificationLink,
  parsePayload,
  shortAgo,
  toTimeInput,
} = await import("../notifications");
type InboxItem = import("../notifications").InboxItem;
type NotificationKind = import("../notifications").NotificationKind;

const NOW = new Date("2026-11-14T17:00:00Z"); // 12:00 PM in New York

function item(kind: NotificationKind, over: Partial<InboxItem> = {}): InboxItem {
  return {
    id: "n1",
    kind,
    created_at: NOW.toISOString(),
    read_at: null,
    event_id: "ev-1",
    hub_id: "hub-1",
    chapter_id: null,
    payload: parsePayload({
      title: "Pickup soccer",
      starts_at: "2026-11-15T21:00:00Z",
      ends_at: "2026-11-15T23:00:00Z",
      timezone: "America/New_York",
      location_hint: "Piedmont Park",
    }),
    hub: { slug: "soccer", name: "Soccer" },
    chapter: null,
    actorName: null,
    ...over,
  };
}

describe("groupNotifications", () => {
  it("splits into Today and Earlier by the local day, keeping order", () => {
    const rows = [
      { id: "a", created_at: "2026-11-14T16:00:00Z" },
      { id: "b", created_at: "2026-11-14T05:30:00Z" }, // 12:30 AM local, still today
      { id: "c", created_at: "2026-11-14T04:30:00Z" }, // 11:30 PM local yesterday
      { id: "d", created_at: "2026-11-01T12:00:00Z" },
    ];
    const groups = groupNotifications(rows, NOW, "America/New_York");
    expect(groups.map((g) => g.title)).toEqual(["Today", "Earlier"]);
    expect(groups[0]!.items.map((r) => r.id)).toEqual(["a", "b"]);
    expect(groups[1]!.items.map((r) => r.id)).toEqual(["c", "d"]);
  });

  it("leaves out empty groups", () => {
    expect(groupNotifications([], NOW, "UTC")).toEqual([]);
    const only = groupNotifications([{ created_at: "2026-11-10T00:00:00Z" }], NOW, "UTC");
    expect(only.map((g) => g.key)).toEqual(["earlier"]);
  });

  it("puts unparseable dates in Earlier", () => {
    const groups = groupNotifications([{ created_at: "nope" }], NOW, "UTC");
    expect(groups.map((g) => g.key)).toEqual(["earlier"]);
  });
});

describe("notificationCopy", () => {
  it("confirms going with when and where", () => {
    const c = notificationCopy(
      item("rsvp_confirmed", { payload: { ...item("rsvp_confirmed").payload, status: "going" } }),
      NOW,
    );
    expect(c.title).toBe("You're going to Pickup soccer");
    expect(c.body).toBe("Sun, Nov 15 · 4:00 to 6:00 PM · Piedmont Park");
  });

  it("confirms the waitlist differently", () => {
    const c = notificationCopy(
      item("rsvp_confirmed", { payload: { title: "Run club", status: "waitlisted" } }),
      NOW,
    );
    expect(c).toEqual({
      title: "You're on the waitlist for Run club",
      body: "We'll tell you if a spot opens.",
    });
  });

  it("counts batched joins", () => {
    const one = notificationCopy(
      item("attendee_joined", { actorName: "Maya", payload: { title: "Run club", count: 1 } }),
      NOW,
    );
    expect(one.title).toBe("Maya joined Run club");
    const two = notificationCopy(
      item("attendee_joined", { actorName: "Maya", payload: { title: "Run club", count: 2 } }),
      NOW,
    );
    expect(two.title).toBe("Maya and 1 other joined Run club");
    const many = notificationCopy(
      item("attendee_joined", { payload: { title: "Run club", count: 4 } }),
      NOW,
    );
    expect(many.title).toBe("Someone and 3 others joined Run club");
  });

  it("names what changed on an update", () => {
    const base = item("event_updated").payload;
    const kinds: [string[], string][] = [
      [["time"], "Pickup soccer has a new time"],
      [["place"], "Pickup soccer has a new place"],
      [["time", "place"], "Pickup soccer has a new time and place"],
    ];
    for (const [changed, title] of kinds) {
      expect(
        notificationCopy(item("event_updated", { payload: { ...base, changed } }), NOW).title,
      ).toBe(title);
    }
  });

  it("shows the cancel reason, the series size and the deleted-host case", () => {
    const base = item("event_cancelled").payload;
    expect(
      notificationCopy(item("event_cancelled", { payload: { ...base, reason: "Rain" } }), NOW),
    ).toEqual({ title: "Pickup soccer is cancelled", body: "Rain" });
    expect(
      notificationCopy(
        item("event_cancelled", { payload: { ...base, reason: null, occurrences: 4 } }),
        NOW,
      ).title,
    ).toBe("Pickup soccer is cancelled (4 dates)");
    expect(
      notificationCopy(
        item("event_cancelled", { payload: { ...base, reason: "host_deleted" } }),
        NOW,
      ).body,
    ).toBe("The host closed their account.");
  });

  it("covers every kind with a title and no student-only wording", () => {
    const kinds: NotificationKind[] = [
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
    ];
    for (const k of kinds) {
      const c = notificationCopy(item(k), NOW);
      expect(c.title.length).toBeGreaterThan(0);
      expect(`${c.title} ${c.body ?? ""}`).not.toMatch(/student|campus|GSU|Georgia State/i);
    }
  });

  it("explains a plan our moderators took down", () => {
    expect(
      notificationCopy(
        item("event_cancelled", { payload: { title: "Run club", reason: "moderator_removed" } }),
        NOW,
      ).body,
    ).toBe("Our moderators took this plan down.");
  });

  it("shows the broadcast body and sender", () => {
    const c = notificationCopy(
      item("broadcast", {
        actorName: "Sam",
        payload: { title: "Run club", body: "Meet at the gate" },
      }),
      NOW,
    );
    expect(c).toEqual({ title: "Sam about Run club", body: "Meet at the gate" });
  });

  it("words claim reviews for both outcomes", () => {
    const ok = notificationCopy(
      item("chapter_claim_update", {
        event_id: null,
        chapter: { slug: "soccer-o4w", name: "Soccer · Old Fourth Ward" },
        payload: { status: "approved" },
      }),
      NOW,
    );
    expect(ok).toEqual({
      title: "Your chapter claim was approved",
      body: "You now organize Soccer · Old Fourth Ward.",
    });
    const no = notificationCopy(
      item("chapter_claim_update", {
        event_id: null,
        payload: { status: "rejected", proposed_name: "Run club East", hub_name: "Running" },
      }),
      NOW,
    );
    expect(no).toEqual({
      title: "Your chapter claim wasn't approved",
      body: "About Run club East in Running.",
    });
  });
});

describe("notificationLink", () => {
  it("opens the plan for event kinds", () => {
    expect(notificationLink(item("event_reminder_2h"))).toEqual({
      to: "/events/$id",
      params: { id: "ev-1" },
    });
  });

  it("opens the chapter for an approved claim and the hub otherwise", () => {
    const approved = item("chapter_claim_update", {
      event_id: null,
      chapter: { slug: "soccer-o4w", name: "x" },
      payload: { status: "approved" },
    });
    expect(notificationLink(approved)).toEqual({
      to: "/chapters/$slug",
      params: { slug: "soccer-o4w" },
    });
    const slugOnly = item("chapter_claim_update", {
      event_id: null,
      payload: { status: "approved", chapter_slug: "from-payload" },
    });
    expect(notificationLink(slugOnly)).toEqual({
      to: "/chapters/$slug",
      params: { slug: "from-payload" },
    });
    const rejected = item("chapter_claim_update", {
      event_id: null,
      payload: { status: "rejected" },
    });
    expect(notificationLink(rejected)).toEqual({ to: "/hubs/$slug", params: { slug: "soccer" } });
    expect(notificationLink({ ...rejected, hub: null })).toBeNull();
  });

  it("falls back to the chapter, then the hub, when there is no event", () => {
    expect(
      notificationLink(
        item("hub_new_event", { event_id: null, chapter: { slug: "c1", name: "C" } }),
      ),
    ).toEqual({ to: "/chapters/$slug", params: { slug: "c1" } });
    expect(notificationLink(item("hub_new_event", { event_id: null }))).toEqual({
      to: "/hubs/$slug",
      params: { slug: "soccer" },
    });
  });
});

describe("parsePayload", () => {
  it("drops wrong types and non-objects", () => {
    expect(parsePayload(null)).toEqual({});
    expect(parsePayload([1])).toEqual({});
    const p = parsePayload({ title: 3, count: "2", changed: ["time", 4], body: "hi" });
    expect(p.title).toBeUndefined();
    expect(p.count).toBeUndefined();
    expect(p.changed).toEqual(["time"]);
    expect(p.body).toBe("hi");
  });
});

describe("small helpers", () => {
  it("badgeLabel caps at 9+", () => {
    expect(badgeLabel(0)).toBeNull();
    expect(badgeLabel(-1)).toBeNull();
    expect(badgeLabel(3)).toBe("3");
    expect(badgeLabel(10)).toBe("9+");
  });

  it("shortAgo", () => {
    expect(shortAgo("2026-11-14T16:59:40Z", NOW)).toBe("Just now");
    expect(shortAgo("2026-11-14T16:55:00Z", NOW)).toBe("5m");
    expect(shortAgo("2026-11-14T14:00:00Z", NOW)).toBe("3h");
    expect(shortAgo("2026-11-13T12:00:00Z", NOW)).toBe("Yesterday");
    expect(shortAgo("bad", NOW)).toBe("");
  });

  it("time inputs round-trip", () => {
    expect(toTimeInput("22:00:00")).toBe("22:00");
    expect(toTimeInput(null)).toBe("");
    expect(fromTimeInput("07:30")).toBe("07:30:00");
    expect(fromTimeInput("25:00")).toBeNull();
    expect(fromTimeInput("")).toBeNull();
  });

  it("broadcastOpen until a day after the end", () => {
    expect(broadcastOpen({ status: "published", ends_at: "2026-11-13T18:00:00Z" }, NOW)).toBe(true);
    expect(broadcastOpen({ status: "published", ends_at: "2026-11-13T16:00:00Z" }, NOW)).toBe(
      false,
    );
    expect(broadcastOpen({ status: "cancelled", ends_at: "2026-11-20T16:00:00Z" }, NOW)).toBe(
      false,
    );
  });

  it("broadcast copy", () => {
    expect(broadcastErrorMessage({ message: "broadcast_limit" })).toMatch(/3 messages/);
    expect(broadcastErrorMessage({ message: "body_length" })).toBe(
      "Messages are 1 to 500 characters.",
    );
    expect(broadcastErrorMessage(new Error("weird"))).toBe("Couldn't send that. Try again.");
    expect(broadcastSentMessage(0)).toBe("Sent. No one else is on this plan yet.");
    expect(broadcastSentMessage(1)).toBe("Sent to 1 person.");
    expect(broadcastSentMessage(5)).toBe("Sent to 5 people.");
  });
});
