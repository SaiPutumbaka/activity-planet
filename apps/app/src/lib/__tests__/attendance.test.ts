import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

const {
  MAX_MET,
  attendanceConfirmation,
  attendanceErrorMessage,
  attendanceWindowOpen,
  attendeesLine,
  barPercent,
  canAnswerAttendance,
  chartMax,
  cleanMet,
  formatPercent,
  formatWeekLabel,
  isForbidden,
  labelStep,
  parseAttendees,
  parseDashboard,
  parseSubmitResult,
  returningRate,
  toggleMet,
} = await import("../attendance");
const { notificationCopy, opensAttendanceSheet } = await import("../notifications");

const END = "2026-11-01T22:00:00Z";
const at = (iso: string) => new Date(iso);
const event = { status: "published", ends_at: END, kind: "member" };

describe("attendanceWindowOpen", () => {
  it("opens at the end and closes 7 days later", () => {
    expect(attendanceWindowOpen(event, at("2026-11-01T21:59:59Z"))).toBe(false);
    expect(attendanceWindowOpen(event, at(END))).toBe(true);
    expect(attendanceWindowOpen(event, at("2026-11-08T22:00:00Z"))).toBe(true);
    expect(attendanceWindowOpen(event, at("2026-11-08T22:00:01Z"))).toBe(false);
  });

  it("is closed for cancelled plans and bad dates", () => {
    expect(
      attendanceWindowOpen({ ...event, status: "cancelled" }, at("2026-11-02T10:00:00Z")),
    ).toBe(false);
    expect(attendanceWindowOpen({ status: "published", ends_at: "nope" })).toBe(false);
  });
});

describe("canAnswerAttendance", () => {
  const now = at("2026-11-02T14:00:00Z");
  it("needs a going RSVP, not the host, not imported", () => {
    expect(canAnswerAttendance({ event, status: "going", isHost: false, now })).toBe(true);
    expect(canAnswerAttendance({ event, status: "interested", isHost: false, now })).toBe(false);
    expect(canAnswerAttendance({ event, status: null, isHost: false, now })).toBe(false);
    expect(canAnswerAttendance({ event, status: "going", isHost: true, now })).toBe(false);
    expect(
      canAnswerAttendance({
        event: { ...event, kind: "imported" },
        status: "going",
        isHost: false,
        now,
      }),
    ).toBe(false);
  });
});

describe("met selection", () => {
  it("toggles and caps at MAX_MET", () => {
    expect(toggleMet([], "a")).toEqual(["a"]);
    expect(toggleMet(["a", "b"], "a")).toEqual(["b"]);
    const full = Array.from({ length: MAX_MET }, (_, i) => `u${i}`);
    expect(toggleMet(full, "extra")).toEqual(full);
    expect(toggleMet(full, "u0")).toHaveLength(MAX_MET - 1);
  });

  it("cleans duplicates and blanks", () => {
    expect(cleanMet(["a", "", "a", " ", "b"])).toEqual(["a", "b"]);
    expect(cleanMet(Array.from({ length: 40 }, (_, i) => `u${i}`))).toHaveLength(MAX_MET);
  });
});

describe("parsing", () => {
  it("reads prompt attendees defensively", () => {
    expect(parseAttendees(null)).toEqual([]);
    expect(
      parseAttendees([
        { id: "a", first_name: "Ana", avatar_url: "https://x/a.jpg" },
        { id: "a", first_name: "Dup" },
        { first_name: "No id" },
        "junk",
        { id: "b", first_name: "", avatar_url: null },
      ]),
    ).toEqual([
      { id: "a", first_name: "Ana", avatar_url: "https://x/a.jpg" },
      { id: "b", first_name: "Member", avatar_url: null },
    ]);
  });

  it("reads submit_attendance's result with fallbacks", () => {
    expect(
      parseSubmitResult(
        { event_id: "e", attended: true, met_count: 2, checked_in: true },
        { eventId: "x", attended: false },
      ),
    ).toEqual({ eventId: "e", attended: true, metCount: 2, checkedIn: true });
    expect(parseSubmitResult(null, { eventId: "x", attended: false })).toEqual({
      eventId: "x",
      attended: false,
      metCount: 0,
      checkedIn: false,
    });
  });

  it("reads chapter_dashboard's jsonb", () => {
    const d = parseDashboard({
      chapter_id: "c",
      weeks: 2,
      timezone: "America/New_York",
      from: "2026-10-26",
      to: "2026-11-08",
      members_count: 14,
      totals: { events_held: 3, distinct_attendees: 9, returning_attendees: 4 },
      by_week: [
        {
          week_start: "2026-10-26",
          events_held: 1,
          going: 5,
          checked_in: 3,
          self_reported: 1,
          distinct_attendees: 4,
          returning_attendees: 1,
        },
        { week_start: "bad" },
        { week_start: "2026-11-02", events_held: 2, distinct_attendees: 6, returning_attendees: 3 },
      ],
    });
    expect(d?.membersCount).toBe(14);
    expect(d?.totals.eventsHeld).toBe(3);
    expect(d?.totals.going).toBe(0);
    expect(d?.byWeek.map((w) => w.weekStart)).toEqual(["2026-10-26", "2026-11-02"]);
    expect(d?.byWeek[0]).toMatchObject({ checkedIn: 3, selfReported: 1, distinctAttendees: 4 });
    expect(parseDashboard(null)).toBeNull();
    expect(parseDashboard({ weeks: 2 })).toBeNull();
  });
});

describe("dashboard helpers", () => {
  it("computes the returning rate", () => {
    expect(returningRate({ distinctAttendees: 0, returningAttendees: 0 })).toBeNull();
    expect(returningRate({ distinctAttendees: 4, returningAttendees: 1 })).toBe(0.25);
    expect(formatPercent(0.254)).toBe("25%");
    expect(formatPercent(null)).toBe("–");
  });

  it("scales bars", () => {
    expect(chartMax([])).toBe(1);
    expect(chartMax([{ distinctAttendees: 3 }, { distinctAttendees: 8 }])).toBe(8);
    expect(barPercent(4, 8)).toBe(50);
    expect(barPercent(0, 8)).toBe(0);
    expect(barPercent(9, 8)).toBe(100);
    expect(barPercent(3, 0)).toBe(0);
  });

  it("labels weeks without a timezone shift and thins them out", () => {
    expect(formatWeekLabel("2026-11-02")).toBe("Nov 2");
    expect(formatWeekLabel("2026-03-30")).toBe("Mar 30");
    expect(formatWeekLabel("x")).toBe("x");
    expect(labelStep(4)).toBe(1);
    expect(labelStep(12)).toBe(2);
    expect(labelStep(26)).toBe(5);
  });
});

describe("copy", () => {
  it("confirms without assuming an audience", () => {
    const cases = [
      attendanceConfirmation({ attended: false, metCount: 0 }),
      attendanceConfirmation({ attended: true, metCount: 0 }),
      attendanceConfirmation({ attended: true, metCount: 1 }),
      attendanceConfirmation({ attended: true, metCount: 3 }),
    ];
    expect(cases[2]?.body).toContain("1 person");
    expect(cases[3]?.body).toContain("3 people");
    for (const c of cases) {
      expect(`${c.title} ${c.body}`).not.toMatch(/student|campus|GSU|Georgia State/i);
    }
  });

  it("names who was going", () => {
    const p = (first_name: string) => ({ id: first_name, first_name, avatar_url: null });
    expect(attendeesLine([])).toBeNull();
    expect(attendeesLine([p("Ana")])).toBe("Ana was going");
    expect(attendeesLine([p("Ana"), p("Ben")])).toBe("Ana and Ben were going");
    expect(attendeesLine([p("Ana"), p("Ben"), p("Cy")])).toBe("Ana, Ben and 1 other were going");
    expect(attendeesLine([p("Ana"), p("Ben"), p("Cy"), p("Di")])).toBe(
      "Ana, Ben and 2 others were going",
    );
  });

  it("maps errors", () => {
    expect(attendanceErrorMessage({ message: "event_not_over" })).toMatch(/hasn't ended/);
    expect(attendanceErrorMessage({ message: "too_many_met" })).toContain(String(MAX_MET));
    expect(attendanceErrorMessage({ message: "Failed to fetch" })).toMatch(/connection/);
    expect(attendanceErrorMessage({ message: "weird" })).toBe("Something went wrong. Try again.");
    expect(isForbidden({ message: "forbidden" })).toBe(true);
    expect(isForbidden(new Error("other"))).toBe(false);
  });
});

describe("inbox checkin_prompt", () => {
  const item = (ends_at?: string, event_id: string | null = "e1") => ({
    kind: "checkin_prompt" as const,
    event_id,
    payload: { title: "Run club", ends_at },
  });
  const now = at("2026-11-02T14:00:00Z");

  it("opens the sheet inside the window only", () => {
    expect(opensAttendanceSheet(item(END), now)).toBe(true);
    expect(opensAttendanceSheet(item(END), at("2026-11-10T00:00:00Z"))).toBe(false);
    expect(opensAttendanceSheet(item(undefined), now)).toBe(false);
    expect(opensAttendanceSheet(item(END, null), now)).toBe(false);
    expect(opensAttendanceSheet({ ...item(END), kind: "event_reminder_day" }, now)).toBe(false);
  });

  it("asks the same question as the sheet", () => {
    const c = notificationCopy({ ...item(END), actorName: null, hub: null, chapter: null }, now);
    expect(c.title).toBe("Did you go to Run club?");
  });
});
