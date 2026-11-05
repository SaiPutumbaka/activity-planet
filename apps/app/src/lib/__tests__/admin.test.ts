import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

import {
  QUEUE_SOURCES,
  SOURCE_LABELS,
  SOURCE_TARGETS,
  adminErrorMessage,
  dueLabel,
  dueTone,
  formatHours,
  minutesUntil,
  queueItemDetail,
  queueItemLink,
  reasonError,
  searchQueryKind,
  totalBreaches,
  totalOpen,
  type QueueItem,
  type Scorecard,
} from "../admin";

function item(over: Partial<QueueItem>): QueueItem {
  return {
    source: "report",
    id: "profile:1",
    title: "Sam",
    detail: "profile",
    priority: 2,
    received_at: "2026-11-05T00:00:00Z",
    due_at: "2026-11-06T00:00:00Z",
    overdue: false,
    minutes_left: 600,
    count: 1,
    can_act: true,
    ref: {},
    ...over,
  };
}

describe("dueLabel and dueTone", () => {
  it("reads time left, due now and overdue", () => {
    expect(dueLabel(45)).toBe("45 min left");
    expect(dueLabel(200)).toBe("3 h 20 min left");
    expect(dueLabel(600)).toBe("10 h left");
    expect(dueLabel(120)).toBe("2 h left");
    expect(dueLabel(3 * 1440)).toBe("3 days left");
    expect(dueLabel(0)).toBe("Due now");
    expect(dueLabel(-125)).toBe("Overdue by 2 h 5 min");
  });
  it("is red when overdue and amber inside four hours", () => {
    expect(dueTone(-1)).toBe("overdue");
    expect(dueTone(239)).toBe("soon");
    expect(dueTone(240)).toBe("ok");
  });
  it("counts minutes to a due time", () => {
    const now = new Date("2026-11-05T10:00:00Z");
    expect(minutesUntil("2026-11-05T12:30:00Z", now)).toBe(150);
    expect(minutesUntil("2026-11-05T09:00:00Z", now)).toBe(-60);
  });
});

describe("queue items", () => {
  it("has a label, a target and an action page for every source", () => {
    for (const s of QUEUE_SOURCES) {
      expect(SOURCE_LABELS[s]).toBeTruthy();
      expect(SOURCE_TARGETS[s]).toBeTruthy();
      expect(queueItemLink({ source: s })).toMatch(/^\/admin\//);
    }
    expect(queueItemLink({ source: "takedown" })).toBe("/admin/takedowns");
    expect(queueItemLink({ source: "place_edit" })).toBe("/admin/places");
  });
  it("describes reports with kind, count and reasons", () => {
    expect(
      queueItemDetail(item({ count: 2, ref: { reasons: ["harassment", "child_safety"] } })),
    ).toBe("Profile · 2 reports · Harassment or bullying, Child safety");
  });
  it("flags a takedown that may show a minor", () => {
    expect(
      queueItemDetail(item({ source: "takedown", detail: "ncii", ref: { involves_minor: true } })),
    ).toBe("May show someone under 18");
    expect(queueItemDetail(item({ source: "takedown", detail: "waiting", ref: {} }))).toBe(
      "Removal request · waiting on the requester",
    );
  });
  it("names calendar suggesters only by count", () => {
    expect(queueItemDetail(item({ source: "calendar", count: 3 }))).toBe("Suggested by 3 members");
    expect(queueItemDetail(item({ source: "calendar", count: 1 }))).toBe("Suggested by a member");
  });
});

describe("scorecard totals", () => {
  const s = {
    queues: {
      report: { open: 2, overdue: 1, due_soon: 0 },
      takedown: { open: 1, overdue: 0, due_soon: 1 },
      place_report: { open: 0, overdue: 0, due_soon: 0 },
      place: { open: 3, overdue: 0, due_soon: 0 },
      place_edit: { open: 0, overdue: 0, due_soon: 0 },
      claim: { open: 1, overdue: 1, due_soon: 0 },
      calendar: { open: 0, overdue: 0, due_soon: 0 },
    },
    breaches_30d: { report: 2, takedown: 0, claim: 1 },
  } as Pick<Scorecard, "queues" | "breaches_30d">;
  it("adds the queues", () => {
    expect(totalOpen(s)).toEqual({ open: 7, overdue: 2, due_soon: 1 });
    expect(totalBreaches(s)).toBe(3);
  });
  it("formats hours", () => {
    expect(formatHours(null)).toBe("None yet");
    expect(formatHours(3)).toBe("3 h");
    expect(formatHours(1.25)).toBe("1.3 h");
  });
});

describe("lookup and ban inputs", () => {
  it("knows what the search accepts", () => {
    expect(searchQueryKind("@sam_r")).toBe("handle");
    expect(searchQueryKind("s")).toBeNull();
    expect(searchQueryKind("a%b")).toBeNull();
    expect(searchQueryKind("sam@example.com")).toBe("email");
    expect(searchQueryKind("@")).toBeNull();
    expect(searchQueryKind("0b7a1c2e-1234-4abc-9def-0123456789ab")).toBe("id");
  });
  it("requires a real reason", () => {
    expect(reasonError("spam")).toMatch(/at least/);
    expect(reasonError("Repeated harassment after a warning")).toBeNull();
    expect(reasonError("x".repeat(501))).toMatch(/under/);
  });
  it("turns server codes into sentences", () => {
    expect(adminErrorMessage({ message: "own_item" })).toMatch(/Another moderator/);
    expect(adminErrorMessage({ message: "cannot_ban_admin" })).toBe("Admins can't be banned.");
    expect(adminErrorMessage(new Error("boom with spaces"))).toBe(
      "Something went wrong. Try again.",
    );
  });
});
