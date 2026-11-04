import { describe, expect, it } from "vitest";
import { isFeed, parseFeed } from "../src/parse/feed.ts";
import { fixture } from "./helpers.ts";

describe("RSS with the event module and hCalendar", () => {
  const items = parseFeed(fixture("events.rss"), {
    sourceUrl: "https://library.example.org/events.rss",
  });

  it("keeps entries that carry event times and skips news", () => {
    expect(items.map((i) => i.title)).toEqual(["Teen Anime Club", "Board Game Night"]);
  });

  it("reads ev:startdate, ev:location, ev:organizer, geo and categories", () => {
    expect(items[0]).toMatchObject({
      uid: "evt-101",
      url: "https://library.example.org/events/teen-anime-club",
      start: "2026-11-12T16:00:00-05:00",
      end: "2026-11-12T17:30:00-05:00",
      location: "Decatur Library, Auditorium",
      host: "DeKalb County Public Library",
      lat: 33.7735,
      lng: -84.2963,
      categories: ["Teens"],
      lane: "feed",
    });
    expect(items[0]?.description).toBe("Watch and talk anime & manga.");
  });

  it("reads hCalendar markup inside an escaped description, and status", () => {
    expect(items[1]).toMatchObject({
      start: "2026-11-14T18:00:00-05:00",
      location: "Main Branch",
      description: "Bring a friend.",
      cancelled: true,
    });
  });
});

describe("Atom", () => {
  const items = parseFeed(fixture("events.atom"), {
    sourceUrl: "https://museum.example.org/programs.atom",
  });
  it("reads entries with xCal times and alternate links; ignores entries without times", () => {
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({
      title: "Members' Night & Tour",
      url: "https://museum.example.org/programs/members-night",
      uid: "tag:museum.example.org,2026:program-55",
      start: "2026-11-20T19:00:00",
      end: "2026-11-20T21:00:00",
      location: "Main Hall",
    });
  });
});

describe("isFeed", () => {
  it("tells feeds from pages", () => {
    expect(isFeed(fixture("events.rss"))).toBe(true);
    expect(isFeed(fixture("events.atom"))).toBe(true);
    expect(isFeed(fixture("microdata.html"))).toBe(false);
  });
});
