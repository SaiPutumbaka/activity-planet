import { describe, expect, it } from "vitest";

import { buildIcs, escapeText, fold, googleCalendarUrl, icsDate, icsFilename } from "../ics";

const octets = (s: string) => new TextEncoder().encode(s).length;

describe("icsDate", () => {
  it("writes the UTC instant in the RFC 5545 basic form", () => {
    expect(icsDate("2026-10-28T22:00:00+00:00")).toBe("20261028T220000Z");
    expect(icsDate("2026-10-28T18:00:00-04:00")).toBe("20261028T220000Z");
    expect(icsDate(new Date(Date.UTC(2026, 0, 2, 3, 4, 5, 678)))).toBe("20260102T030405Z");
  });
});

describe("escapeText", () => {
  it("escapes backslash, semicolon and comma, and turns CRLF, CR and LF into \\n", () => {
    expect(escapeText("a\\b;c,d")).toBe("a\\\\b\\;c\\,d");
    expect(escapeText("one\ntwo\r\nthree")).toBe("one\\ntwo\\nthree");
    expect(escapeText("old\rmac\r\n\rend")).toBe("old\\nmac\\n\\nend");
    expect(escapeText("plain: text")).toBe("plain: text");
  });
});

describe("fold", () => {
  it("leaves a line of 75 octets alone", () => {
    const line = "x".repeat(75);
    expect(fold(line)).toBe(line);
  });

  it("folds at 75 octets with a leading space on each continuation", () => {
    const line = `DESCRIPTION:${"a".repeat(200)}`;
    const parts = fold(line).split("\r\n");
    expect(parts.length).toBeGreaterThan(1);
    for (const part of parts) expect(octets(part)).toBeLessThanOrEqual(75);
    expect(octets(parts[0]!)).toBe(75);
    for (const part of parts.slice(1)) expect(part.startsWith(" ")).toBe(true);
    expect(parts.map((p, i) => (i === 0 ? p : p.slice(1))).join("")).toBe(line);
  });

  it("counts UTF-8 octets and never splits a character", () => {
    const line = `SUMMARY:${"é".repeat(60)}🏀`;
    const parts = fold(line).split("\r\n");
    for (const part of parts) expect(octets(part)).toBeLessThanOrEqual(75);
    expect(parts.map((p, i) => (i === 0 ? p : p.slice(1))).join("")).toBe(line);
  });
});

describe("buildIcs", () => {
  const event = {
    id: "75f5d251-14a6-4505-bbdb-b304490276d5",
    title: "Pickup, then tacos; bring water",
    startsAt: "2026-11-05T21:00:00+00:00",
    endsAt: "2026-11-05T23:00:00+00:00",
    description: "Line one\nLine two",
    location: "Piedmont Park",
    url: "https://activity-planet.vercel.app/e/75f5d251-14a6-4505-bbdb-b304490276d5",
  };

  it("writes one VEVENT with CRLF endings, UTC times and escaped text", () => {
    const ics = buildIcs(event, new Date("2026-11-01T12:00:00Z"));
    expect(ics.endsWith("\r\n")).toBe(true);
    expect(ics.split("\r\n").every((l) => octets(l) <= 75)).toBe(true);
    const unfolded = ics.replace(/\r\n /g, "");
    expect(unfolded).toContain("UID:75f5d251-14a6-4505-bbdb-b304490276d5@activityplanet.app\r\n");
    expect(unfolded).toContain("DTSTAMP:20261101T120000Z\r\n");
    expect(unfolded).toContain("DTSTART:20261105T210000Z\r\nDTEND:20261105T230000Z\r\n");
    expect(unfolded).toContain("SUMMARY:Pickup\\, then tacos\\; bring water\r\n");
    expect(unfolded).toContain("DESCRIPTION:Line one\\nLine two\r\n");
    expect(unfolded).toContain(`URL:${event.url}\r\n`);
  });

  it("drops LOCATION and DESCRIPTION when there is nothing to say", () => {
    const ics = buildIcs({ ...event, location: "", description: null });
    expect(ics).not.toContain("LOCATION:");
    expect(ics).not.toContain("DESCRIPTION:");
  });
});

describe("googleCalendarUrl", () => {
  it("prefills title, UTC dates, details and location", () => {
    const url = new URL(
      googleCalendarUrl({
        id: "x",
        title: "Board games",
        startsAt: "2026-11-05T21:00:00Z",
        endsAt: "2026-11-05T23:00:00Z",
        description: "Bring one",
        location: "Midtown",
        url: "https://example.test/e/x",
      }),
    );
    expect(url.origin + url.pathname).toBe("https://calendar.google.com/calendar/render");
    expect(url.searchParams.get("action")).toBe("TEMPLATE");
    expect(url.searchParams.get("text")).toBe("Board games");
    expect(url.searchParams.get("dates")).toBe("20261105T210000Z/20261105T230000Z");
    expect(url.searchParams.get("details")).toBe("Bring one\n\nhttps://example.test/e/x");
    expect(url.searchParams.get("location")).toBe("Midtown");
  });

  it("does not repeat a URL the description already carries", () => {
    const url = new URL(
      googleCalendarUrl({
        id: "x",
        title: "Board games",
        startsAt: "2026-11-05T21:00:00Z",
        endsAt: "2026-11-05T23:00:00Z",
        description: "Open: https://example.test/e/x",
        url: "https://example.test/e/x",
      }),
    );
    expect(url.searchParams.get("details")).toBe("Open: https://example.test/e/x");
    expect(url.searchParams.has("location")).toBe(false);
  });
});

describe("icsFilename", () => {
  it("slugs the title", () => {
    expect(icsFilename("Pickup Basketball @ 5!")).toBe("pickup-basketball-5.ics");
    expect(icsFilename("🏀")).toBe("plan.ics");
  });
});
