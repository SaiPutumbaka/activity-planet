import { describe, expect, it } from "vitest";

import {
  clampRadiusKm,
  distanceBandLabel,
  feedSection,
  groupFeed,
  nextRadiusKm,
  roundCoordinate,
  roundPoint,
} from "../index";

// 2026-11-12 is a Thursday. 23:30 in Atlanta (EST, UTC-5) is 04:30 UTC on the 13th.
const lateThursdayAtlanta = new Date("2026-11-13T04:30:00Z");

describe("feedSection", () => {
  it("uses Atlanta's calendar day, not UTC's", () => {
    // 01:00 UTC on the 13th is still 8 PM Thursday in Atlanta: today.
    expect(feedSection("2026-11-13T01:00:00Z", lateThursdayAtlanta)).toBe("today");
    // 05:30 UTC on the 13th is 00:30 Friday in Atlanta: the next day, so this week.
    expect(feedSection("2026-11-13T05:30:00Z", lateThursdayAtlanta)).toBe("this_week");
  });

  it("files something already under way as today", () => {
    expect(feedSection("2026-11-12T20:00:00Z", lateThursdayAtlanta)).toBe("today");
  });

  it("puts the next six days in this week and day seven onwards in later", () => {
    // Wednesday Nov 18, noon Atlanta: six days out.
    expect(feedSection("2026-11-18T17:00:00Z", lateThursdayAtlanta)).toBe("this_week");
    // Thursday Nov 19, noon Atlanta: seven days out.
    expect(feedSection("2026-11-19T17:00:00Z", lateThursdayAtlanta)).toBe("later");
  });

  it("follows the timezone it is given", () => {
    // Same instants in Los Angeles (PST, UTC-8): now is 20:30 Thursday, the event 21:30 Thursday.
    expect(feedSection("2026-11-13T05:30:00Z", lateThursdayAtlanta, "America/Los_Angeles")).toBe(
      "today",
    );
  });

  it("handles the DST change (Nov 1 2026 falls back)", () => {
    const now = new Date("2026-10-31T16:00:00Z"); // Sat noon EDT
    expect(feedSection("2026-11-01T04:30:00Z", now)).toBe("this_week"); // Sun 00:30 EDT
    expect(feedSection("2026-11-01T03:30:00Z", now)).toBe("today"); // Sat 23:30 EDT
  });
});

describe("groupFeed", () => {
  const ev = (id: string, starts_at: string, kind = "member") => ({ id, starts_at, kind });

  it("groups human-hosted plans into ordered sections and keeps imported apart", () => {
    const events = [
      ev("later", "2026-11-25T17:00:00Z"),
      ev("today", "2026-11-13T01:00:00Z"),
      ev("imp", "2026-11-13T02:00:00Z", "imported"),
      ev("week", "2026-11-14T17:00:00Z", "chapter"),
      ev("today2", "2026-11-13T03:00:00Z"),
    ];
    const { sections, imported } = groupFeed(events, lateThursdayAtlanta);
    expect(sections.map((s) => s.key)).toEqual(["today", "this_week", "later"]);
    expect(sections.map((s) => s.title)).toEqual(["Today", "This week", "Later"]);
    expect(sections[0]?.events.map((e) => e.id)).toEqual(["today", "today2"]);
    expect(sections[1]?.events.map((e) => e.id)).toEqual(["week"]);
    expect(imported.map((e) => e.id)).toEqual(["imp"]);
  });

  it("leaves out empty sections", () => {
    const { sections, imported } = groupFeed(
      [ev("x", "2026-11-25T17:00:00Z")],
      lateThursdayAtlanta,
    );
    expect(sections.map((s) => s.key)).toEqual(["later"]);
    expect(imported).toEqual([]);
  });

  it("returns nothing for nothing", () => {
    expect(groupFeed([], lateThursdayAtlanta)).toEqual({ sections: [], imported: [] });
  });
});

describe("nextRadiusKm", () => {
  it("widens 10 -> 25 -> 50 while results are fewer than five", () => {
    expect(nextRadiusKm(10, 0)).toBe(25);
    expect(nextRadiusKm(25, 4)).toBe(50);
    expect(nextRadiusKm(50, 0)).toBeNull();
  });

  it("starts the ladder at 10 from a smaller radius", () => {
    expect(nextRadiusKm(5, 2)).toBe(10);
  });

  it("stops once there are enough results", () => {
    expect(nextRadiusKm(10, 5)).toBeNull();
    expect(nextRadiusKm(5, 12)).toBeNull();
  });

  it("respects a custom threshold", () => {
    expect(nextRadiusKm(10, 2, 2)).toBeNull();
    expect(nextRadiusKm(10, 1, 2)).toBe(25);
  });
});

describe("clampRadiusKm", () => {
  it("keeps radii between 1 and 50 and defaults to 10", () => {
    expect(clampRadiusKm(25)).toBe(25);
    expect(clampRadiusKm(0)).toBe(1);
    expect(clampRadiusKm(80)).toBe(50);
    expect(clampRadiusKm(null)).toBe(10);
    expect(clampRadiusKm(Number.NaN)).toBe(10);
  });
});

describe("roundCoordinate and roundPoint", () => {
  it("rounds to two decimals", () => {
    expect(roundCoordinate(33.74901)).toBe(33.75);
    expect(roundCoordinate(-84.38804)).toBe(-84.39);
    expect(roundCoordinate(33.744)).toBe(33.74);
    expect(roundCoordinate(-0.001)).toBe(0);
  });

  it("rounds a point and refuses one that is not on Earth", () => {
    expect(roundPoint(33.7490123, -84.3880456)).toEqual({ lat: 33.75, lng: -84.39 });
    expect(roundPoint(91, 0)).toBeNull();
    expect(roundPoint(0, -181)).toBeNull();
    expect(roundPoint(Number.NaN, 0)).toBeNull();
  });
});

describe("distanceBandLabel", () => {
  it("words every band", () => {
    expect(distanceBandLabel("approximate")).toBe("Approximate area");
    expect(distanceBandLabel("<1 mi")).toBe("Under 1 mi");
    expect(distanceBandLabel("1-5 mi")).toBe("1 to 5 mi");
    expect(distanceBandLabel("5-10 mi")).toBe("5 to 10 mi");
    expect(distanceBandLabel("10-25 mi")).toBe("10 to 25 mi");
    expect(distanceBandLabel("25+ mi")).toBe("25+ mi");
    expect(distanceBandLabel(null)).toBeNull();
    expect(distanceBandLabel("weird")).toBeNull();
  });
});
