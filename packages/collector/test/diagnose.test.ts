import { describe, expect, it } from "vitest";
import { collect } from "../src/collect.ts";
import {
  type DiagnosticEntry,
  detectBodyType,
  expectsFeed,
  formatDiagnostic,
  jsonLdTypes,
  looksLikeChallenge,
  mediaType,
  pageHints,
  redactForLog,
} from "../src/diagnose.ts";
import { DryRunIngest } from "../src/ingest.ts";
import { PoliteFetcher } from "../src/net/fetcher.ts";
import { Denylist } from "../src/policy/denylist.ts";
import type { CityFile, Seed } from "../src/types.ts";
import { ATL, fakeClock, fakeTransport, fixture, NOW, type FakeResponse } from "./helpers.ts";

const entry = (over: Partial<DiagnosticEntry> = {}): DiagnosticEntry => ({
  sourceKey: "atl-beltline",
  url: "https://beltline.org/events/?ical=1",
  status: 200,
  finalUrl: "https://beltline.org/events/?ical=1",
  contentType: "text/html; charset=UTF-8",
  bytes: 48213,
  robots: "allow",
  verdict: "not_a_feed detected=html",
  ...over,
});

describe("formatDiagnostic", () => {
  it("prints one line of request metadata with the verdict last", () => {
    expect(formatDiagnostic(entry())).toBe(
      "[diagnose] source=atl-beltline url=https://beltline.org/events/?ical=1 status=200 final_host=beltline.org type=text/html bytes=48213 robots=allow verdict=not_a_feed detected=html",
    );
  });

  it("shows the host the redirects ended on, and dashes for what is unknown", () => {
    const line = formatDiagnostic(
      entry({
        url: "https://events.example.org/events",
        finalUrl: "https://example.libnet.info/events",
        status: null,
        contentType: null,
        bytes: null,
        robots: "disallow",
        verdict: "fetch_failed reason=robots_disallowed",
      }),
    );
    expect(line).toContain(" final_host=example.libnet.info ");
    expect(line).toContain(" status=- ");
    expect(line).toContain(" type=- bytes=- robots=disallow ");
    expect(line).toMatch(/verdict=fetch_failed reason=robots_disallowed$/);
    // Never requested (precheck): no final host.
    expect(formatDiagnostic(entry({ finalUrl: null, status: null }))).toContain(" final_host=- ");
  });

  it("marks a 304 served from the cache", () => {
    expect(formatDiagnostic(entry({ status: 304, cached: true }))).toContain(
      " status=304(cached) ",
    );
  });

  it("redacts secrets in the query and drops user info and fragments", () => {
    const line = formatDiagnostic(
      entry({
        url: "https://user:pw@app.ticketmaster.com/discovery/v2/events.json?apikey=tm-secret&geoPoint=dn5bp&client_id=sg-id&access_token=abc&page=0#frag",
      }),
    );
    expect(line).not.toMatch(/tm-secret|sg-id|abc|user|pw@|frag/);
    expect(line).toContain("apikey=REDACTED");
    expect(line).toContain("client_id=REDACTED");
    expect(line).toContain("access_token=REDACTED");
    expect(line).toContain("geoPoint=dn5bp");
    // Feed switches stay visible.
    expect(redactForLog("https://parkpride.org/events/?ical=1")).toBe(
      "https://parkpride.org/events/?ical=1",
    );
    expect(redactForLog("not a url")).toBe("(bad url)");
  });

  it("hides the path of organizer-connected feeds and hosted calendar services", () => {
    const gcal = "https://calendar.google.com/calendar/ical/someone%40gmail.com/public/basic.ics";
    expect(redactForLog(gcal)).toBe("https://calendar.google.com/_path_hidden_");
    expect(redactForLog("https://p42-caldav.icloud.com/published/2/abc")).toBe(
      "https://p42-caldav.icloud.com/_path_hidden_",
    );
    expect(redactForLog("https://club.example.org/me@x.org/cal.ics", { hidePath: true })).toBe(
      "https://club.example.org/_path_hidden_",
    );
    const line = formatDiagnostic(
      entry({ sourceKey: "org-0123456789ab", url: "https://club.example.org/u/jo/cal.ics" }),
    );
    expect(line).toContain(" url=https://club.example.org/_path_hidden_ ");
    expect(line).not.toContain("/u/jo");
    expect(formatDiagnostic(entry())).toContain("url=https://beltline.org/events/?ical=1");
  });

  it("keeps every field on one line with a fixed character set", () => {
    const line = formatDiagnostic(
      entry({
        sourceKey: "evil\nsource id",
        contentType: "text/html\r\nx-injected: 1",
        robots: "allow\nverdict=fake",
        verdict: "html jsonld events=0\n[dry-run] fake <script>",
      }),
    );
    expect(line.split("\n")).toHaveLength(1);
    expect(line).not.toMatch(/[<>\r]/);
    expect(line).toContain("source=evil_source_id ");
    expect(line).toContain(" type=other ");
  });

  it("reduces Content-Type to the media type", () => {
    expect(mediaType("Text/Calendar; charset=utf-8")).toBe("text/calendar");
    expect(mediaType(null)).toBe("-");
    expect(mediaType("garbage value")).toBe("other");
  });
});

describe("detectBodyType and expectsFeed", () => {
  it("sniffs feeds, pages and other bodies from their first bytes", () => {
    expect(detectBodyType(fixture("calendar.ics"))).toBe("ics");
    expect(detectBodyType(`\uFEFF\r\n${fixture("calendar.ics")}`)).toBe("ics");
    expect(detectBodyType(fixture("events.rss"))).toBe("rss");
    expect(detectBodyType(fixture("events.atom"))).toBe("atom");
    expect(detectBodyType(fixture("microdata.html"))).toBe("html");
    expect(detectBodyType("<!DOCTYPE html><html><head><title>x</title>")).toBe("html");
    expect(detectBodyType('{"events": []}')).toBe("json");
    expect(detectBodyType('<?xml version="1.0"?><root/>')).toBe("xml");
    expect(detectBodyType("   ")).toBe("empty");
    expect(detectBodyType("Service unavailable")).toBe("text");
  });

  it("calls an HTML body html even when it is served as text/calendar", () => {
    expect(detectBodyType("<!doctype html><html><body>Events</body></html>", "text/calendar")).toBe(
      "html",
    );
  });

  it("knows feed export URLs", () => {
    expect(expectsFeed("https://beltline.org/events/?ical=1")).toBe(true);
    expect(expectsFeed("https://x.example.org/events/?post_type=tribe_events&ical=1")).toBe(true);
    expect(expectsFeed("https://x.example.org/cal/events.ics")).toBe(true);
    expect(
      expectsFeed("https://mariettaga.gov/common/modules/iCalendar/iCalendar.aspx?catID=14"),
    ).toBe(true);
    // CivicPlus's bare iCalendar.aspx is the page listing the feeds.
    expect(expectsFeed("https://mariettaga.gov/iCalendar.aspx")).toBe(false);
    expect(expectsFeed("https://x.example.org/events/")).toBe(false);
    expect(expectsFeed("https://x.example.org/events/?ical=10")).toBe(false);
  });

  it("names JSON-LD types and spots challenge pages without printing text", () => {
    expect(
      jsonLdTypes([
        '{"@context":"https://schema.org","@type":"Organization","name":"Secret Title"}',
        '{"@graph":[{"@type":["WebSite","Thing"]},{"@type":"Bad Type!"}]}',
      ]),
    ).toEqual(["Organization", "WebSite", "Thing"]);
    expect(looksLikeChallenge("<html><head><title>Just a moment...</title></head></html>")).toBe(
      true,
    );
    expect(looksLikeChallenge(fixture("microdata.html"))).toBe(false);
  });
});

// A feed seed whose ?ical=1 answers with the events page, and the same on a page seed's
// discovered export link: both are not_a_feed with the detected type, counted per source.
const HTML_PAGE =
  '<!DOCTYPE html><html><head><title>Upcoming Events - Secret Title</title></head><body><h1>Events</h1><a href="/calendar/?ical=1">iCal</a></body></html>';

const ROUTES: Record<string, FakeResponse> = {
  "https://feeds.example.org/robots.txt": { body: "User-agent: *\nCrawl-delay: 3\n" },
  "https://feeds.example.org/events/?ical=1": {
    body: HTML_PAGE,
    headers: { "content-type": "text/html; charset=UTF-8" },
  },
  "https://feeds.example.org/good/?ical=1": {
    body: fixture("calendar.ics"),
    headers: { "content-type": "text/calendar" },
  },
  "https://feeds.example.org/calendar/": {
    body: HTML_PAGE,
    headers: { "content-type": "text/html" },
  },
  // Served as text/calendar, but it is the events page.
  "https://feeds.example.org/calendar/?ical=1": {
    body: HTML_PAGE,
    headers: { "content-type": "text/calendar; charset=utf-8" },
  },
};

const seed = (s: Partial<Seed> & Pick<Seed, "id" | "kind" | "url">): Seed => ({
  name: "Feeds Example",
  attribution: "Listed from the example calendar (feeds.example.org).",
  ...s,
});

const CITY: CityFile = {
  region: ATL,
  seeds: [
    seed({ id: "test-html-ics", kind: "ics", url: "https://feeds.example.org/events/?ical=1" }),
    seed({ id: "test-good-ics", kind: "ics", url: "https://feeds.example.org/good/?ical=1" }),
    seed({ id: "test-page", kind: "page", url: "https://feeds.example.org/calendar/" }),
  ],
};

async function run() {
  const fc = fakeClock();
  const { transport } = fakeTransport(ROUTES, fc.clock);
  const fetcher = new PoliteFetcher({
    denylist: Denylist.load(),
    transport,
    now: fc.now,
    sleep: fc.sleep,
  });
  const lines: string[] = [];
  const result = await collect({
    regions: [ATL],
    cities: [CITY],
    fetcher,
    now: NOW,
    concurrency: 1,
    diagnose: (e) => lines.push(formatDiagnostic(e)),
  });
  return { result, lines };
}

describe("HTML instead of ICS", () => {
  it("is not_a_feed with the detected type, counted in each source's summary", async () => {
    const { result } = await run();
    const by = Object.fromEntries(result.batches.map((b) => [b.sourceKey, b]));
    expect(by["test-html-ics"]!.items).toHaveLength(0);
    expect(by["test-html-ics"]!.errors).toEqual({ "not_a_feed:html": 1 });
    expect(
      result.errors.find((e) => e.sourceKey === "test-html-ics" && e.reason === "not_a_feed")
        ?.detected,
    ).toBe("html");
    // The page seed's discovered ?ical=1 export answered with HTML too.
    expect(by["test-page"]!.errors).toEqual({ "not_a_feed:html": 1 });
    expect(by["test-good-ics"]!.items.length).toBeGreaterThan(0);
    expect(by["test-good-ics"]!.errors).toEqual({});

    const out: string[] = [];
    const ingest = new DryRunIngest((l) => out.push(l));
    for (const b of result.batches) await ingest.send(b);
    expect(out.find((l) => l.includes("source=test-html-ics"))).toMatch(
      /errors=\{not_a_feed:html=1\}$/,
    );
  });

  it("prints one diagnose line per request with counts and no page text", async () => {
    const { lines } = await run();
    expect(lines).toHaveLength(4);
    const [htmlIcs, goodIcs, page, discovered] = lines;
    expect(htmlIcs).toBe(
      "[diagnose] source=test-html-ics url=https://feeds.example.org/events/?ical=1 status=200 final_host=feeds.example.org type=text/html bytes=" +
        new TextEncoder().encode(HTML_PAGE).length +
        " robots=allow,crawl-delay=3 verdict=not_a_feed detected=html",
    );
    expect(goodIcs).toMatch(
      /source=test-good-ics .* type=text\/calendar .*verdict=ics vevents=\d+ events=\d+$/,
    );
    expect(page).toMatch(
      /source=test-page url=https:\/\/feeds\.example\.org\/calendar\/ .*verdict=html no-event-markup jsonld blocks=0 microdata items=0 hints anchors=1 event_path_anchors=0 feed links found=1 page links found=0$/,
    );
    expect(discovered).toMatch(
      /source=test-page url=https:\/\/feeds\.example\.org\/calendar\/\?ical=1 .* type=text\/calendar .*verdict=not_a_feed detected=html$/,
    );
    const all = lines.join("\n");
    expect(all).not.toMatch(/Secret|Upcoming|Run Club|Weekly/);
  });
});

describe("pageHints", () => {
  it("names the platform, embed hosts and anchor counts, never page text", () => {
    const html = `<!doctype html><html><head><script src="/wp-includes/js/x.js"></script>
      <script src="https://widgets.example-cal.com/embed.js"></script></head>
      <body><div id="root"></div><iframe src="https://calendar.example.org/embed?x=1"></iframe>
      <a href="/events/secret-title-here/">Secret Title Here</a><a href="/about/">About</a></body></html>`;
    const hints = pageHints(html, "https://www.beltline.org/events/list/");
    expect(hints).toEqual([
      "wordpress",
      "js-app-root",
      "iframes=calendar.example.org",
      "script_hosts=widgets.example-cal.com",
      "anchors=2",
      "event_path_anchors=1",
    ]);
    expect(hints.join(" ")).not.toMatch(/Secret|secret-title/);
  });
});
