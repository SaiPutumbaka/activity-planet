import { describe, expect, it } from "vitest";
import { discoverLinks, scanHtml } from "../src/parse/html.ts";
import { jsonLdEvents, parseJsonLdBlock, schemaEvents } from "../src/parse/schema.ts";
import { fixture } from "./helpers.ts";

const PAGE = "https://parks.example.gov/events/";

describe("JSON-LD @graph with @id references", () => {
  const scan = scanHtml(fixture("jsonld-graph.html"), PAGE);
  const events = jsonLdEvents(scan.jsonLd, { pageUrl: PAGE });

  it("finds Event and subtypes, not other nodes", () => {
    expect(events.map((e) => e.title)).toEqual(["Sunrise Yoga in the Park", "Jazz on the Lawn"]);
  });

  it("resolves the Place by @id with PostalAddress and GeoCoordinates", () => {
    expect(events[0]).toMatchObject({
      uid: "https://parks.example.gov/events/yoga/#event",
      url: "https://parks.example.gov/events/yoga/",
      start: "2026-11-15T08:00",
      end: "2026-11-15T09:00",
      location: "Piedmont Park, 1320 Monroe Dr NE, Atlanta, GA",
      lat: 33.7851,
      lng: -84.3738,
      isFree: true,
      host: "Piedmont Park Conservancy",
      cancelled: false,
      lane: "page",
    });
    expect(events[0]?.description).toBe("Bring a mat. All levels welcome.");
    // The image is read but only used when the seed licenses images (normalize drops it).
    expect(events[0]?.imageUrl).toBe("https://parks.example.gov/img/yoga.jpg");
  });

  it("reads a text location, relative url, offer range, cancelled status and subtype category", () => {
    expect(events[1]).toMatchObject({
      url: "https://parks.example.gov/events/jazz/",
      location: "Piedmont Park Lawn, Atlanta, GA",
      lat: null,
      isFree: false,
      priceText: "From $15",
      cancelled: true,
      categories: ["Music"],
    });
  });
});

describe("JSON-LD variants", () => {
  const scan = scanHtml(fixture("jsonld-variants.html"), "https://learn.example.org/calendar");
  const events = jsonLdEvents(scan.jsonLd, { pageUrl: "https://learn.example.org/calendar" });

  it("tolerates HTML comments, trailing commas and a broken block", () => {
    expect(scan.jsonLd).toHaveLength(2);
    expect(parseJsonLdBlock("{ this is not json }")).toEqual([]);
    expect(events.map((e) => e.title)).toEqual([
      "Intro to Python (online)",
      "Holiday Play",
      "Postponed Gala",
    ]);
  });

  it("marks online events and free offers", () => {
    expect(events[0]).toMatchObject({ online: true, location: "Online", isFree: true, lat: null });
    expect(events[0]?.categories).toEqual(["Education"]);
  });

  it("reads events nested in an ItemList, text addresses and AggregateOffer", () => {
    expect(events[1]).toMatchObject({
      start: "2026-12-05",
      location: "Community Theater, 123 Main St, Decatur, GA",
      priceText: "$12",
      isFree: false,
    });
    // No url of its own: the page it is listed on.
    expect(events[1]?.url).toBe("https://learn.example.org/calendar");
  });

  it("flags postponed events (normalize leaves them out)", () => {
    expect(events[2]?.postponed).toBe(true);
  });
});

describe("microdata", () => {
  const page = "https://library.example.org/calendar";
  const scan = scanHtml(fixture("microdata.html"), page);
  const events = schemaEvents(scan.microdata, { pageUrl: page });

  it("builds top-level items with nested Place, PostalAddress and GeoCoordinates", () => {
    expect(scan.microdata).toHaveLength(3);
    expect(events).toHaveLength(2);
    expect(events[0]).toMatchObject({
      title: "Knitting Circle",
      url: "https://library.example.org/events/knitting-circle",
      start: "2026-11-16T14:00",
      end: "2026-11-16T15:30",
      location: "Ponce de Leon Branch, 980 Ponce de Leon Ave NE, Atlanta",
      lat: 33.7737,
      lng: -84.357,
      description: "Yarn provided. Beginners welcome.",
      imageUrl: "https://library.example.org/img/knit.jpg",
    });
  });

  it("reads content attributes and http schema.org types", () => {
    expect(events[1]).toMatchObject({
      title: "Pickup Soccer",
      start: "2026-11-17T18:00:00-05:00",
      location: "Grant Park field 2",
      categories: ["Sports"],
    });
  });
});

describe("feed and event-page discovery", () => {
  const scan = scanHtml(fixture("jsonld-graph.html"), PAGE);
  const links = discoverLinks(scan, (u) => new URL(u).hostname === "parks.example.gov");

  it("finds <link rel=alternate> calendar and RSS feeds and calendar anchors (webcal as https)", () => {
    expect(links.feeds.sort()).toEqual(
      [
        "https://parks.example.gov/events/?ical=1",
        "https://parks.example.gov/events/feed/",
        "https://parks.example.gov/calendar.ics",
      ].sort(),
    );
  });

  it("finds same-site event pages, skipping rel=nofollow, other sites and login links", () => {
    expect(links.pages.sort()).toEqual([
      "https://parks.example.gov/events/tai-chi/",
      "https://parks.example.gov/events/yoga/",
    ]);
  });

  it("reads robots meta tags", () => {
    expect(scan.metas).toContainEqual({ name: "robots", content: "index, follow" });
  });
});

describe("discovery on CivicPlus and RSS index pages", () => {
  it("follows CivicPlus iCalendar feed links and RSS index links", () => {
    const page = "https://mariettaga.gov/iCalendar.aspx";
    const scan = scanHtml(
      [
        '<a href="/common/modules/iCalendar/iCalendar.aspx?catID=14&amp;feed=calendar">Parks</a>',
        '<a href="/common/modules/iCalendar/iCalendar.aspx?catID=22&amp;feed=calendar">City</a>',
        '<a href="https://www.calendar.gatech.edu/rss/arts">Arts RSS</a>',
        '<a href="/news.rss">News</a>',
        '<a href="/about">About</a>',
      ].join(""),
      page,
    );
    const { feeds, pages } = discoverLinks(scan, () => true);
    expect(feeds).toEqual([
      "https://mariettaga.gov/common/modules/iCalendar/iCalendar.aspx?catID=14&feed=calendar",
      "https://mariettaga.gov/common/modules/iCalendar/iCalendar.aspx?catID=22&feed=calendar",
      "https://www.calendar.gatech.edu/rss/arts",
      "https://mariettaga.gov/news.rss",
    ]);
    expect(pages).toEqual([]);
  });

  it("finds nothing to follow when every anchor is rel=nofollow", () => {
    const scan = scanHtml(
      '<a rel="nofollow" href="/events/a">A</a><a rel="nofollow" href="/x.ics">B</a>',
      PAGE,
    );
    expect(discoverLinks(scan, () => true)).toEqual({ feeds: [], pages: [], skipped: {} });
  });
});
