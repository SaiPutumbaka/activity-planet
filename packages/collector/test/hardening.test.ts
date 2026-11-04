// Review fixes: SSRF guards, markup that survives decoding, API keys and the cache, linear-time
// feed and HTML scans, recurrence edge cases, API redirects, denylist gaps, snippet directives
// and the region filter for items without a point. Fixtures and in-memory inputs only.

import { describe, expect, it } from "vitest";
import { collect } from "../src/collect.ts";
import { inAnyRegion } from "../src/filter.ts";
import { isBlockedIp, publicHostProblem, safeLookup } from "../src/net/address.ts";
import { MemoryHttpCache } from "../src/net/cache.ts";
import { defaultTransport, PoliteFetcher } from "../src/net/fetcher.ts";
import { normalize } from "../src/normalize.ts";
import { parseFeed } from "../src/parse/feed.ts";
import { parseIcs } from "../src/parse/ics.ts";
import { expandRRule, parseRRule } from "../src/parse/rrule.ts";
import { Denylist } from "../src/policy/denylist.ts";
import {
  mergeDirectives,
  metaDirectives,
  parseXRobotsTag,
  snippetLimit,
} from "../src/policy/meta.ts";
import type { CityFile, Region, RawEvent } from "../src/types.ts";
import { htmlToText, plain } from "../src/util/text.ts";
import { fetchableUrl } from "../src/util/url.ts";
import { zonedToUtc } from "../src/util/time.ts";
import {
  ATL,
  fakeClock,
  fakeTransport,
  fixture,
  NOW,
  WINDOW_END,
  type FakeResponse,
} from "./helpers.ts";

const deny = Denylist.load();

function setup(routes: Record<string, FakeResponse>, cache = new MemoryHttpCache()) {
  const c = fakeClock();
  const { transport, log } = fakeTransport(routes, c.clock);
  const fetcher = new PoliteFetcher({
    denylist: deny,
    transport,
    now: c.now,
    sleep: c.sleep,
    cache,
  });
  return { fetcher, log, cache };
}

describe("SSRF: only public hosts on port 443", () => {
  const { fetcher } = setup({});

  it("rejects loopback, private, link-local, metadata and private-use names before any request", () => {
    for (const url of [
      "https://127.0.0.1/x.ics",
      "https://127.1.2.3/",
      "https://localhost/x",
      "https://foo.localhost/x",
      "https://169.254.169.254/latest/meta-data/",
      "https://10.0.0.5/",
      "https://172.16.4.1/",
      "https://192.168.1.1/cal.ics",
      "https://100.64.0.1/",
      "https://0.0.0.0/",
      "https://[::1]/",
      "https://[::]/",
      "https://[fe80::1]/",
      "https://[fd00::1]/",
      "https://[::ffff:127.0.0.1]/",
      "https://[::ffff:a9fe:a9fe]/",
      "https://[64:ff9b::a9fe:a9fe]/",
      "https://metadata.google.internal/",
      "https://printer.local/",
      "https://router.home.arpa/",
      "https://intranet/",
      "https://2130706433/", // 127.0.0.1 in decimal; URL normalizes it
      "https://0x7f.1/",
      "https://a.example.org:8443/",
      "https://a.example.org:80/",
      "https://user:pw@a.example.org/",
    ]) {
      expect(fetcher.precheck(url), url).toBe("private_address");
    }
  });

  it("allows public hosts and IPs", () => {
    expect(fetcher.precheck("https://www.example.gov/calendar")).toBeNull();
    expect(fetcher.precheck("https://a.example.org:443/x")).toBeNull();
    expect(fetcher.precheck("https://93.184.215.14/")).toBeNull();
    expect(fetcher.precheck("https://[2606:2800:21f:cb07:6820:80da:af6b:8b2c]/")).toBeNull();
    expect(publicHostProblem(new URL("https://beltline.org/events/"))).toBeNull();
  });

  it("classifies IP literals by range", () => {
    for (const ip of [
      "127.0.0.1",
      "10.1.1.1",
      "172.31.255.255",
      "192.168.0.1",
      "169.254.1.1",
      "100.127.0.1",
      "224.0.0.1",
      "255.255.255.255",
      "::1",
      "fc00::1",
      "fe80::abcd",
      "::ffff:10.0.0.1",
      "2002:7f00:1::",
    ]) {
      expect(isBlockedIp(ip), ip).toBe(true);
    }
    for (const ip of [
      "8.8.8.8",
      "172.32.0.1",
      "100.128.0.1",
      "2001:4860:4860::8888",
      "::ffff:8.8.8.8",
    ]) {
      expect(isBlockedIp(ip), ip).toBe(false);
    }
  });

  it("an http:// link to a LAN address is upgraded to https but still refused", () => {
    const url = fetchableUrl("http://192.168.1.1/cal.ics");
    expect(url).toBe("https://192.168.1.1/cal.ics");
    expect(fetcher.precheck(url as string)).toBe("private_address");
  });

  it("refuses a redirect hop into the private network without requesting it", async () => {
    const { fetcher: f, log } = setup({
      "https://a.example.org/robots.txt": { body: "" },
      "https://a.example.org/go": {
        status: 302,
        headers: { location: "https://169.254.169.254/latest/meta-data/" },
      },
    });
    expect(await f.get("https://a.example.org/go")).toMatchObject({
      ok: false,
      reason: "private_address",
    });
    expect(log.some((l) => l.url.includes("169.254"))).toBe(false);
  });

  it("the connect-time lookup refuses names that resolve to loopback (rebinding guard)", async () => {
    const err = await new Promise<NodeJS.ErrnoException | null>((resolve) =>
      safeLookup("localhost", { all: true }, (e) => resolve(e)),
    );
    expect(err?.code).toBe("EBLOCKEDADDRESS");
    // The default transport uses it, so even a URL that skipped precheck cannot connect.
    const failure = await defaultTransport()("https://localhost/", { method: "GET" }).then(
      () => null,
      (e: unknown) => e as { cause?: { code?: string } },
    );
    expect(failure?.cause?.code).toBe("EBLOCKEDADDRESS");
  });
});

describe("no markup survives into item text", () => {
  it("strips markup revealed by decoding, and leaves no angle brackets", () => {
    const out = plain("&amp;lt;img src=x onerror=alert(1)&amp;gt; <b>y</b>");
    expect(out).not.toMatch(/[<>]/);
    expect(out).not.toMatch(/<img/i);
    expect(out).toContain("y");
    expect(plain("&lt;script&gt;alert(1)&lt;/script&gt;Hi")).not.toMatch(/[<>]/);
    expect(htmlToText("<p>&lt;b&gt;bold&lt;/b&gt;</p>")).toBe("bold");
    expect(plain("Ages 5 < 12")).not.toMatch(/[<>]/);
  });

  it("an ICS SUMMARY or DESCRIPTION with encoded markup normalizes to plain text", () => {
    const raw: RawEvent = {
      lane: "feed",
      uid: "x",
      title: "&amp;lt;b&amp;gt;Concert&amp;lt;/b&amp;gt; <i>night</i>",
      description: "&amp;lt;img src=x onerror=alert(1)&amp;gt; <b>y</b>",
      url: "https://example.org/e",
      start: "2026-11-10T14:00:00Z",
      end: null,
      location: "Park",
      lat: null,
      lng: null,
      sourceUrl: "https://example.org/cal.ics",
    };
    const r = normalize(raw, { region: ATL, attribution: "t" });
    if (!r.ok) throw new Error(r.reason);
    expect(r.item.title).not.toMatch(/[<>]/);
    expect(r.item.description).not.toMatch(/[<>]/);
  });
});

describe("API keys never reach the HTTP cache", () => {
  it("does not store or revalidate API responses", async () => {
    const url = "https://app.ticketmaster.com/discovery/v2/events.json?apikey=SECRET";
    const { fetcher, cache, log } = setup({
      [url]: { body: "{}", headers: { etag: '"v1"', "content-type": "application/json" } },
    });
    expect((await fetcher.get(url, { api: true })).ok).toBe(true);
    expect(cache.get(url)).toBeUndefined();
    expect((await fetcher.get(url, { api: true })).ok).toBe(true);
    expect(log.every((l) => l.headers["if-none-match"] === undefined)).toBe(true);
  });
});

describe("API-lane redirects", () => {
  it("refuses a redirect off the official API endpoints", async () => {
    const url = "https://api.seatgeek.com/2/events?client_id=K";
    const { fetcher, log } = setup({
      [url]: { status: 302, headers: { location: "https://tracker.example.org/x" } },
    });
    expect(await fetcher.get(url, { api: true, headers: { "x-key": "K" } })).toMatchObject({
      ok: false,
      reason: "http_error",
    });
    expect(log.map((l) => l.url)).toEqual([url]);
  });

  it("follows a redirect between API endpoints, dropping custom headers when the host changes", async () => {
    const a = "https://api.seatgeek.com/2/events?page=1";
    const b = "https://app.ticketmaster.com/discovery/v2/events.json?page=1";
    const { fetcher, log } = setup({
      [a]: { status: 302, headers: { location: b } },
      [b]: { body: "{}" },
    });
    expect((await fetcher.get(a, { api: true, headers: { "x-key": "K" } })).ok).toBe(true);
    expect(log[0]?.headers["x-key"]).toBe("K");
    expect(log[1]?.url).toBe(b);
    expect(log[1]?.headers["x-key"]).toBeUndefined();
  });

  it("drops custom headers on a cross-host redirect in the page lane too", async () => {
    const { fetcher, log } = setup({
      "https://a.example.org/robots.txt": { body: "" },
      "https://b.example.org/robots.txt": { body: "" },
      "https://a.example.org/x": {
        status: 301,
        headers: { location: "https://b.example.org/y" },
      },
      "https://b.example.org/y": { body: "ok" },
    });
    expect((await fetcher.get("https://a.example.org/x", { headers: { "x-t": "1" } })).ok).toBe(
      true,
    );
    const y = log.find((l) => l.url === "https://b.example.org/y");
    expect(y?.headers["x-t"]).toBeUndefined();
  });
});

describe("linear-time scans of hostile input", () => {
  const budgetMs = 1500;
  const time = (fn: () => unknown) => {
    const t0 = performance.now();
    fn();
    return performance.now() - t0;
  };

  it("an RSS feed full of unclosed <item> and <title> tags", () => {
    const xml = `<rss><channel>${"<item><title>x ".repeat(100_000)}</channel></rss>`;
    expect(xml.length).toBeGreaterThan(1_000_000);
    expect(time(() => parseFeed(xml, { sourceUrl: "https://a.example.org/f" }))).toBeLessThan(
      budgetMs,
    );
    const atom = `<feed>${"<entry><summary>".repeat(80_000)}</feed>`;
    expect(time(() => parseFeed(atom, { sourceUrl: "https://a.example.org/f" }))).toBeLessThan(
      budgetMs,
    );
  });

  it("one closed item holding many unclosed classed elements and CDATA openers", () => {
    const desc = '<span class="dt-start location">x '.repeat(30_000) + "<![CDATA[ ".repeat(30_000);
    const xml = `<rss><channel><item><title>T</title><description>${desc}</description></item></channel></rss>`;
    expect(time(() => parseFeed(xml, { sourceUrl: "https://a.example.org/f" }))).toBeLessThan(
      budgetMs,
    );
  });

  it("HTML text with unclosed <script>, <style> and stray '<'", () => {
    const html = "<script>a ".repeat(60_000) + "<style>b ".repeat(60_000) + "< c".repeat(100_000);
    expect(html.length).toBeGreaterThan(1_000_000);
    expect(time(() => htmlToText(html))).toBeLessThan(budgetMs);
    expect(htmlToText("a<script>x</script>b<style>y</style>c<script>unclosed")).toBe("a b c");
  });
});

describe("recurrence edge cases", () => {
  const opts = {
    sourceUrl: "https://www.example.gov/cal.ics",
    defaultZone: "America/New_York",
    windowStart: NOW,
    windowEnd: WINDOW_END,
  };
  const events = parseIcs(fixture("recurrence-old.ics"), opts);
  const byTitle = (t: string) => events.filter((e) => e.title === t);

  it("past RDATEs do not use up the per-event cap", () => {
    const rd = byTitle("Story Time (RDATE list)");
    expect(rd.map((e) => e.start)).toEqual(["2026-11-18T15:00:00.000Z"]);
  });

  it("rules with a decades-old DTSTART still reach the window", () => {
    const walk = byTitle("Morning Walk (since 1970)");
    expect(walk).toHaveLength(60);
    expect(walk[0]?.start).toBe("2026-11-04T14:00:00.000Z");
    expect(walk.at(-1)?.start).toBe("2027-01-02T14:00:00.000Z");
    expect(byTitle("Council Meeting (since 1975)").map((e) => e.start)).toEqual([
      "2026-11-19T23:00:00.000Z",
    ]);
    const tg = byTitle("Thanksgiving Closure (since 1980)");
    expect(tg.map((e) => e.start)).toEqual(["2026-11-26T05:00:00.000Z"]);
    expect(tg[0]?.allDay).toBe(true);
  });

  it("skipping ahead matches walking from DTSTART", () => {
    const rule = parseRRule("FREQ=WEEKLY;INTERVAL=3;BYDAY=MO,TH");
    if (!rule) throw new Error("rule");
    const dtstart = { year: 2001, month: 3, day: 5, hour: 19, minute: 0, second: 0 };
    const toInstant = (c: typeof dtstart) => zonedToUtc(c, "America/New_York");
    const fast = expandRRule(rule, dtstart, { toInstant, until: null, from: NOW, to: WINDOW_END });
    const slow = expandRRule({ ...rule, count: 1_000_000 }, dtstart, {
      toInstant,
      until: null,
      from: NOW,
      to: WINDOW_END,
    });
    expect(fast.length).toBeGreaterThan(0);
    expect(fast).toEqual(slow);
  });

  it("hundreds of old weekly rules expand quickly, and total work per file is capped", () => {
    const lines = ["BEGIN:VCALENDAR", "VERSION:2.0"];
    for (let i = 0; i < 300; i++) {
      lines.push(
        "BEGIN:VEVENT",
        `UID:w${i}@example.gov`,
        "DTSTART;TZID=America/New_York:19800107T190000",
        "DTEND;TZID=America/New_York:19800107T200000",
        "RRULE:FREQ=DAILY;BYDAY=MO",
        `SUMMARY:Weekly Club ${i}`,
        "END:VEVENT",
      );
    }
    // A rule that never matches (February 30th) and has a COUNT, so it cannot skip ahead.
    lines.push(
      "BEGIN:VEVENT",
      "UID:never@example.gov",
      "DTSTART:19700101T000000Z",
      "RRULE:FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30;COUNT=5",
      "SUMMARY:Never",
      "END:VEVENT",
      "END:VCALENDAR",
    );
    const t0 = performance.now();
    const out = parseIcs(lines.join("\r\n"), opts);
    expect(performance.now() - t0).toBeLessThan(3000);
    // Mondays from Nov 9 to Dec 28.
    expect(out.filter((e) => e.title === "Weekly Club 0")).toHaveLength(8);
    expect(out.filter((e) => e.title === "Weekly Club 299")).toHaveLength(8);
  });

  it("stops expanding when the shared work budget runs out", () => {
    const rule = parseRRule("FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30;COUNT=5");
    if (!rule) throw new Error("rule");
    const budget = { left: 1000 };
    const dtstart = { year: 1970, month: 1, day: 1, hour: 0, minute: 0, second: 0 };
    const toInstant = (c: typeof dtstart) => zonedToUtc(c, "UTC");
    expandRRule(rule, dtstart, { toInstant, until: null, from: NOW, to: WINDOW_END, budget });
    expect(budget.left).toBeLessThan(0);
    expect(budget.left).toBeGreaterThan(-5);
  });
});

describe("denylist gaps", () => {
  it("blocks country sites, Meta short links, Eventbrite CDN and new TLDs", () => {
    for (const url of [
      "https://nextdoor.co.uk/events/1",
      "https://nextdoor.ca/x",
      "https://nextdoor.com.au/x",
      "https://www.evbuc.com/x",
      "https://www.threads.net/@a",
      "https://m.me/page",
      "https://seatgeek.co.uk/x",
      "https://www.seatgeek.com/atlanta",
      "https://eventbrite.events/x",
      "https://www.ticketmaster.de/x",
    ]) {
      expect(deny.check(url).denied, url).toBe(true);
    }
    expect(deny.check("https://api.seatgeek.com/2/events", { allowApi: true }).denied).toBe(false);
    expect(deny.check("https://eventbrite.example.org/").denied).toBe(false);
  });
});

describe("nosnippet and max-snippet", () => {
  it("parses both from meta tags and X-Robots-Tag, strictest wins", () => {
    expect(parseXRobotsTag("nosnippet")).toMatchObject({ nosnippet: true, noindex: false });
    expect(parseXRobotsTag("max-snippet: 50")).toMatchObject({ maxSnippet: 50 });
    expect(parseXRobotsTag("max-snippet:-1").maxSnippet).toBeNull();
    expect(
      metaDirectives([{ name: "robots", content: "max-snippet:20, max-image-preview:large" }]),
    ).toMatchObject({ maxSnippet: 20 });
    const merged = mergeDirectives(
      parseXRobotsTag("max-snippet:100"),
      metaDirectives([{ name: "robots", content: "max-snippet:40" }]),
    );
    expect(snippetLimit(merged, 280)).toBe(40);
    expect(snippetLimit(parseXRobotsTag("nosnippet"), 280)).toBe(0);
    expect(snippetLimit(parseXRobotsTag("max-snippet:0"), 280)).toBe(0);
    expect(snippetLimit(parseXRobotsTag(null), 280)).toBe(280);
  });

  it("collect drops or clips the excerpt per the source's directives", async () => {
    const city: CityFile = {
      region: ATL,
      seeds: [
        {
          id: "nosnip",
          kind: "ics",
          url: "https://a.example.org/cal.ics",
          name: "A",
          attribution: "Listed from A (a.example.org).",
        },
        {
          id: "short",
          kind: "page",
          url: "https://b.example.org/events",
          name: "B",
          attribution: "Listed from B (b.example.org).",
          discover: false,
        },
      ],
    };
    const c = fakeClock();
    const { transport } = fakeTransport(
      {
        "https://a.example.org/robots.txt": { body: "" },
        "https://a.example.org/cal.ics": {
          body: fixture("calendar.ics"),
          headers: { "content-type": "text/calendar", "x-robots-tag": "nosnippet" },
        },
        "https://b.example.org/robots.txt": { body: "" },
        "https://b.example.org/events": {
          body: '<meta name="robots" content="max-snippet:10">' + fixture("jsonld-graph.html"),
          headers: { "content-type": "text/html" },
        },
      },
      c.clock,
    );
    const fetcher = new PoliteFetcher({ denylist: deny, transport, now: c.now, sleep: c.sleep });
    const result = await collect({
      regions: [ATL],
      cities: [city],
      fetcher,
      env: {},
      now: NOW,
      windowDays: 60,
    });
    const by = Object.fromEntries(result.batches.map((b) => [b.sourceKey, b.items]));
    expect(by.nosnip?.length).toBeGreaterThan(0);
    expect(by.nosnip?.every((i) => i.description === "")).toBe(true);
    expect(by.short?.length).toBeGreaterThan(0);
    expect(by.short?.every((i) => i.description.length <= 10)).toBe(true);
  });
});

describe("region filter for items without a point", () => {
  const item = { lat: null, lng: null } as Parameters<typeof inAnyRegion>[0];
  const small: Region = { id: "u1", label: "Small", lat: 34.05, lng: -84.6, radiusKm: 5 };

  it("keeps them only when the source's own area is centred inside a requested region", () => {
    expect(inAnyRegion(item, [ATL], ATL)).toBe(true);
    expect(inAnyRegion(item, [small], ATL)).toBe(false); // Atlanta's centre is ~40 km away
    expect(inAnyRegion(item, [small], small)).toBe(true); // an API asked about this region
  });
});
