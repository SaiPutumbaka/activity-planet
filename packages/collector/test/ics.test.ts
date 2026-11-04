import { describe, expect, it } from "vitest";
import { parseDuration, parseIcs, parseLine, unescapeText, unfold } from "../src/parse/ics.ts";
import { expandRRule, parseRRule } from "../src/parse/rrule.ts";
import { zonedToUtc } from "../src/util/time.ts";
import { fixture, NOW, WINDOW_END } from "./helpers.ts";

const opts = {
  sourceUrl: "https://www.example.gov/iCalendar.aspx",
  defaultZone: "America/Chicago",
  windowStart: NOW,
  windowEnd: WINDOW_END,
};

describe("ics lexing", () => {
  it("unfolds continuation lines and keeps CRLF and LF alike", () => {
    expect(unfold("A:one\r\n  two\r\nB:x\n\tY")).toEqual(["A:one two", "B:xY"]);
  });
  it("parses quoted parameters containing colons and semicolons", () => {
    const p = parseLine('DTSTART;TZID="America/New_York";X-A="a:b;c":20261110T190000');
    expect(p).toEqual({
      name: "DTSTART",
      params: { TZID: "America/New_York", "X-A": "a:b;c" },
      value: "20261110T190000",
    });
  });
  it("unescapes TEXT", () => {
    expect(unescapeText("a\\, b\\; c\\\\d\\ne\\Nf")).toBe("a, b; c\\d\ne\nf");
  });
  it("parses durations", () => {
    expect(parseDuration("PT1H30M")).toBe(5_400_000);
    expect(parseDuration("P1D")).toBe(86_400_000);
    expect(parseDuration("P1W")).toBe(604_800_000);
    expect(parseDuration("-PT15M")).toBe(-900_000);
    expect(parseDuration("junk")).toBeNull();
  });
});

describe("parseIcs on a CivicPlus-style feed", () => {
  const events = parseIcs(fixture("calendar.ics"), opts);
  const byTitle = (t: string) => events.filter((e) => e.title === t);

  it("reads a single event with TZID, GEO, categories and organizer", () => {
    const [e] = byTitle("Farmers Market, Square Edition");
    expect(e).toMatchObject({
      uid: "single-1@example.gov",
      start: "2026-11-11T00:00:00.000Z", // 7 pm EST
      end: "2026-11-11T01:30:00.000Z",
      location: "Marietta Square, 50 N Park Sq",
      lat: 33.9526,
      lng: -84.5499,
      categories: ["Community", "Food"],
      host: "City of Example",
      allDay: false,
      lane: "feed",
    });
    expect(e?.description).toContain("Fresh produce\nand music");
    // No URL property: the first https link in the description is used.
    expect(e?.url).toBe("https://www.example.gov/market");
  });

  it("expands a weekly RRULE in wall-clock time across the DST change, inside the window", () => {
    const runs = events.filter((e) => e.uid?.startsWith("weekly-1@example.gov#"));
    // COUNT=8 from Oct 28: Oct 28 is before the window, Nov 11 is an EXDATE.
    expect(runs.map((e) => e.start)).toEqual([
      "2026-11-04T23:00:00.000Z", // 6 pm EST (DTSTART was 6 pm EDT = 22:00Z)
      "2026-11-19T00:00:00.000Z", // overridden to 7 pm
      "2026-11-25T23:00:00.000Z", // cancelled override
      "2026-12-02T23:00:00.000Z",
      "2026-12-09T23:00:00.000Z",
      "2026-12-16T23:00:00.000Z",
    ]);
    expect(runs[0]?.end).toBe("2026-11-05T00:30:00.000Z");
    expect(runs[1]?.title).toBe("Weekly Run Club (late start)");
    expect(runs[2]?.cancelled).toBe(true);
    expect(runs.filter((e) => e.cancelled)).toHaveLength(1);
    // Instance ids stay tied to the original slot, even when an override moves it.
    expect(runs[1]?.uid).toBe("weekly-1@example.gov#2026-11-18T23:00:00.000Z");
  });

  it("reads all-day events in the calendar zone with an inclusive end", () => {
    const [e] = byTitle("Fall Festival");
    expect(e).toMatchObject({
      allDay: true,
      start: "2026-11-21T05:00:00.000Z",
      end: "2026-11-22T04:59:00.000Z",
    });
  });

  it("expands BYDAY ordinals: second Tuesday and last Friday", () => {
    expect(byTitle("Second Tuesday Council Meeting").map((e) => e.start)).toEqual([
      "2026-11-10T23:00:00.000Z",
      "2026-12-08T23:00:00.000Z",
    ]);
    expect(byTitle("Last Friday Art Walk").map((e) => e.start)).toEqual([
      "2026-11-28T01:00:00.000Z",
      "2026-12-26T01:00:00.000Z",
    ]);
  });

  it("reads floating times in X-WR-TIMEZONE and Windows zone names", () => {
    expect(byTitle("Floating Story Time")[0]?.start).toBe("2026-11-12T15:00:00.000Z");
    const [lunch] = events.filter((e) => e.uid === "windows-1@example.gov");
    expect(lunch?.start).toBe("2026-11-13T17:00:00.000Z");
    expect(lunch?.title).toBe(
      "Lunch and Learn with a very long folded summary that continues on the next line",
    );
  });

  it("drops private and out-of-window events", () => {
    expect(byTitle("Staff only")).toHaveLength(0);
    expect(byTitle("Long gone")).toHaveLength(0);
  });

  it("falls back to the default zone when the calendar names none", () => {
    const ics =
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nDTSTART:20261112T100000\nSUMMARY:Floating\nEND:VEVENT\nEND:VCALENDAR\n";
    expect(parseIcs(ics, opts)[0]?.start).toBe("2026-11-12T16:00:00.000Z"); // 10 am CST
  });
});

describe("rrule", () => {
  const ny = (c: Parameters<typeof zonedToUtc>[0]) => zonedToUtc(c, "America/New_York");
  const base = { year: 2026, month: 1, day: 31, hour: 9, minute: 0, second: 0 };

  it("skips months without the day (monthly on the 31st)", () => {
    const rule = parseRRule("FREQ=MONTHLY;COUNT=4")!;
    const out = expandRRule(rule, base, {
      toInstant: ny,
      until: null,
      from: new Date(0),
      to: new Date("2027-01-01"),
    });
    expect(out.map((c) => `${c.month}-${c.day}`)).toEqual(["1-31", "3-31", "5-31", "7-31"]);
  });

  it("honours INTERVAL, UNTIL and BYSETPOS", () => {
    const daily = parseRRule("FREQ=DAILY;INTERVAL=3;UNTIL=20260210T000000Z")!;
    const d = expandRRule(
      daily,
      { ...base, month: 2, day: 1 },
      {
        toInstant: ny,
        until: new Date("2026-02-10T00:00:00Z"),
        from: new Date(0),
        to: new Date("2027-01-01"),
      },
    );
    expect(d.map((c) => c.day)).toEqual([1, 4, 7]);
    const lastWeekday = parseRRule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3")!;
    const l = expandRRule(
      lastWeekday,
      { ...base, month: 1, day: 30 },
      { toInstant: ny, until: null, from: new Date(0), to: new Date("2027-01-01") },
    );
    expect(l.map((c) => `${c.month}-${c.day}`)).toEqual(["1-30", "2-27", "3-31"]);
  });

  it("expands yearly BYMONTH and weekly multi-day rules", () => {
    const yearly = parseRRule("FREQ=YEARLY;BYMONTH=7;BYMONTHDAY=4;COUNT=2")!;
    const y = expandRRule(
      yearly,
      { ...base, month: 7, day: 4 },
      { toInstant: ny, until: null, from: new Date(0), to: new Date("2030-01-01") },
    );
    expect(y.map((c) => c.year)).toEqual([2026, 2027]);
    const weekly = parseRRule("FREQ=WEEKLY;BYDAY=TU,TH;COUNT=4")!;
    const w = expandRRule(
      weekly,
      { ...base, month: 11, day: 3 },
      { toInstant: ny, until: null, from: new Date(0), to: new Date("2027-01-01") },
    );
    expect(w.map((c) => c.day)).toEqual([3, 5, 10, 12]);
  });

  it("stops at the window end even without COUNT or UNTIL", () => {
    const rule = parseRRule("FREQ=DAILY")!;
    const out = expandRRule(
      rule,
      { ...base, year: 2020, month: 1, day: 1 },
      {
        toInstant: ny,
        until: null,
        from: NOW,
        to: new Date(NOW.getTime() + 3 * 86_400_000),
      },
    );
    expect(out).toHaveLength(3);
  });

  it("rejects rules without a known FREQ", () => {
    expect(parseRRule("FREQ=SECONDLY")).toBeNull();
    expect(parseRRule("COUNT=3")).toBeNull();
  });
});
