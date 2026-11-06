import { describe, expect, it } from "vitest";

import {
  US_PREFS,
  acceptLanguageLocale,
  clockParts,
  formatAddressLine,
  formatClock,
  formatClockRange,
  formatDay,
  formatDayClock,
  formatWeekdayClock,
  formatKm,
  formatKmRange,
  formatKmRough,
  formatMeters,
  localePrefs,
} from "../index";

const NY = "America/New_York";
const BERLIN = "Europe/Berlin";
// Thu Nov 5 2026, 21:00 UTC = 4:00 PM in New York, 22:00 in Berlin.
const T = new Date(Date.UTC(2026, 10, 5, 21, 0));
const T2 = new Date(Date.UTC(2026, 10, 5, 23, 0));
const NOW = new Date(Date.UTC(2026, 10, 1, 12, 0));

describe("localePrefs", () => {
  it("reads unit, clock and date order from the locale", () => {
    expect(localePrefs("en-US")).toEqual({ unit: "mi", hour12: true, dayFirst: false });
    expect(localePrefs("en-GB")).toEqual({ unit: "mi", hour12: false, dayFirst: true });
    expect(localePrefs("de-DE")).toEqual({ unit: "km", hour12: false, dayFirst: true });
    expect(localePrefs("fr-FR")).toEqual({ unit: "km", hour12: false, dayFirst: true });
    expect(localePrefs("en-AU")).toMatchObject({ unit: "km", hour12: true, dayFirst: true });
    expect(localePrefs("ja-JP")).toMatchObject({ unit: "km", hour12: false, dayFirst: false });
    expect(localePrefs("en-CA")).toMatchObject({ unit: "km", dayFirst: false });
  });
  it("falls back to US conventions", () => {
    expect(localePrefs(undefined)).toEqual(US_PREFS);
    expect(localePrefs("")).toEqual(US_PREFS);
    expect(localePrefs("not a locale!!")).toEqual(US_PREFS);
  });
  it("reads the first Accept-Language tag", () => {
    expect(acceptLanguageLocale("de-DE,de;q=0.9,en;q=0.8")).toBe("de-DE");
    expect(acceptLanguageLocale("*")).toBeUndefined();
    expect(acceptLanguageLocale(null)).toBeUndefined();
  });
});

describe("clock", () => {
  const de = localePrefs("de-DE");
  it("is 12-hour or 24-hour", () => {
    expect(formatClock(T, NY)).toBe("4:00 PM");
    expect(formatClock(T, NY, de)).toBe("16:00");
    expect(formatClock(T, BERLIN, de)).toBe("22:00");
    expect(formatClock(new Date(Date.UTC(2026, 10, 5, 5, 5)), NY, de)).toBe("00:05");
    expect(clockParts(T, NY, de)).toEqual({ clock: "16:00", period: "" });
  });
  it("formats ranges", () => {
    expect(formatClockRange(T, T2, NY)).toBe("4:00 to 6:00 PM");
    expect(formatClockRange(new Date(Date.UTC(2026, 10, 5, 16, 30)), T2, NY)).toBe(
      "11:30 AM to 6:00 PM",
    );
    expect(formatClockRange(T, T2, NY, de)).toBe("16:00 to 18:00");
  });
  it("is empty for an invalid date", () => {
    expect(formatClock("nope", NY)).toBe("");
  });
});

describe("day", () => {
  const gb = localePrefs("en-GB");
  it("puts month or day first, English words either way", () => {
    expect(formatDay(T, NY, US_PREFS, { now: NOW })).toBe("Thu, Nov 5");
    expect(formatDay(T, NY, gb, { now: NOW })).toBe("Thu 5 Nov");
    expect(formatDay(T, NY, gb, { now: NOW, weekday: false })).toBe("5 Nov");
    expect(formatDay(T, NY, US_PREFS, { now: NOW, weekday: "long", month: "long" })).toBe(
      "Thursday, November 5",
    );
  });
  it("adds the year when it is not this year", () => {
    const later = new Date(Date.UTC(2027, 0, 9, 18, 0));
    expect(formatDay(later, NY, US_PREFS, { now: NOW })).toBe("Sat, Jan 9, 2027");
    expect(formatDay(later, NY, gb, { now: NOW })).toBe("Sat 9 Jan 2027");
    expect(formatDay(T, NY, US_PREFS, { now: NOW, year: true })).toBe("Thu, Nov 5, 2026");
  });
  it("gives a weekday and clock", () => {
    expect(formatWeekdayClock(T, NY)).toBe("Thu 4:00 PM");
    expect(formatWeekdayClock(T, NY, localePrefs("de-DE"))).toBe("Thu 16:00");
  });
  it("joins day and clock", () => {
    expect(formatDayClock(T, NY, US_PREFS, { now: NOW })).toBe("Thu, Nov 5 · 4:00 PM");
    expect(formatDayClock(T, BERLIN, localePrefs("de-DE"), { now: NOW })).toBe("Thu 5 Nov · 22:00");
  });
});

describe("distances", () => {
  it("shows a km radius in the viewer's unit", () => {
    expect(formatKm(25, "km")).toBe("25 km");
    expect(formatKm(25, "mi")).toBe("16 mi");
    expect(formatKm(5, "mi")).toBe("3 mi");
    expect(formatKm(1, "mi")).toBe("1 mi");
    expect(formatKmRange(1, 50, "km")).toBe("1 to 50 km");
    expect(formatKmRange(1, 50, "mi")).toBe("1 to 31 mi");
  });
  it("gives rough sizes for copy", () => {
    expect(formatKmRough(1, "km")).toBe("1 km");
    expect(formatKmRough(1, "mi")).toBe("half a mile");
    expect(formatKmRough(10, "mi")).toBe("6 mi");
    expect(formatKmRough(11, "mi")).toBe("7 mi");
  });
  it("shows a measured distance", () => {
    expect(formatMeters(320, "km")).toBe("300 m");
    expect(formatMeters(2100, "km")).toBe("2.1 km");
    expect(formatMeters(12_400, "km")).toBe("12 km");
    expect(formatMeters(50, "mi")).toBe("0.1 mi");
    expect(formatMeters(2253, "mi")).toBe("1.4 mi");
    expect(formatMeters(20_000, "mi")).toBe("12 mi");
  });
});

describe("formatAddressLine", () => {
  it("keeps the US order where it is the norm or the country is unknown", () => {
    expect(
      formatAddressLine({
        address_line1: "25 Park Pl",
        city: "Atlanta",
        state: "GA",
        postal_code: "30303",
        country: "US",
      }),
    ).toBe("25 Park Pl, Atlanta, GA 30303");
    expect(
      formatAddressLine({ address_line1: "1 Main St", city: "Springfield", country: null }),
    ).toBe("1 Main St, Springfield");
  });
  it("puts the postcode before the town where that is the norm", () => {
    expect(
      formatAddressLine({
        address_line1: "Schlossbergring",
        city: "Freiburg im Breisgau",
        state: "",
        postal_code: "79098",
        country: "DE",
      }),
    ).toBe("Schlossbergring, 79098 Freiburg im Breisgau");
  });
  it("uses a source's formatted line as it is", () => {
    expect(
      formatAddressLine({
        address_line1: "Werthmannstraße 4, 79098 Freiburg im Breisgau",
        city: "Freiburg im Breisgau",
        country: "DE",
      }),
    ).toBe("Werthmannstraße 4, 79098 Freiburg im Breisgau");
  });
  it("adds the town when the street only happens to share a word with it", () => {
    expect(
      formatAddressLine({
        address_line1: "100 Atlanta Ave SE",
        city: "Atlanta",
        state: "GA",
        postal_code: "30315",
        country: "US",
      }),
    ).toBe("100 Atlanta Ave SE, Atlanta, GA 30315");
    expect(
      formatAddressLine({
        address_line1: "Hauptstr. 1",
        city: "Au",
        postal_code: "79280",
        country: "DE",
      }),
    ).toBe("Hauptstr. 1, 79280 Au");
    expect(
      formatAddressLine({
        address_line1: "12 Main St, Newark",
        city: "New",
        state: "NY",
        country: "US",
      }),
    ).toBe("12 Main St, Newark, New, NY");
  });
  it("is empty with no parts", () => {
    expect(formatAddressLine({})).toBe("");
  });
});
