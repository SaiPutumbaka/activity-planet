import { describe, expect, it } from "vitest";
import { MemoryHttpCache } from "../src/net/cache.ts";
import { PoliteFetcher, USER_AGENT } from "../src/net/fetcher.ts";
import { Denylist } from "../src/policy/denylist.ts";
import { fakeClock, fakeTransport, type FakeResponse } from "./helpers.ts";

const deny = Denylist.load();

function setup(
  routes: Record<string, FakeResponse | ((h: Record<string, string>) => FakeResponse)>,
  extra = {},
) {
  const c = fakeClock();
  const { transport, log } = fakeTransport(routes, c.clock);
  const fetcher = new PoliteFetcher({
    denylist: deny,
    transport,
    now: c.now,
    sleep: c.sleep,
    ...extra,
  });
  return { fetcher, log, clock: c.clock };
}

const OK_ROBOTS = { body: "User-agent: *\nDisallow: /private/\n" };

describe("PoliteFetcher", () => {
  it("sends the identifying User-Agent with no email, and reads robots.txt first", async () => {
    const { fetcher, log } = setup({
      "https://a.example.org/robots.txt": OK_ROBOTS,
      "https://a.example.org/events": {
        body: "<html></html>",
        headers: { "content-type": "text/html" },
      },
    });
    const res = await fetcher.get("https://a.example.org/events");
    expect(res.ok).toBe(true);
    expect(log.map((l) => l.url)).toEqual([
      "https://a.example.org/robots.txt",
      "https://a.example.org/events",
    ]);
    expect(log[1]?.headers["user-agent"]).toBe(USER_AGENT);
    expect(USER_AGENT).toBe("ActivityPlanetBot/0.1 (+https://activity-planet.vercel.app/bot)");
    expect(USER_AGENT).not.toMatch(/@/);
  });

  it("spaces requests to one host at least 2 seconds apart, and caches robots.txt per host", async () => {
    const { fetcher, log } = setup({
      "https://a.example.org/robots.txt": OK_ROBOTS,
      "https://a.example.org/1": { body: "1" },
      "https://a.example.org/2": { body: "2" },
      "https://a.example.org/3": { body: "3" },
      "https://b.example.org/robots.txt": { status: 404 },
      "https://b.example.org/1": { body: "b" },
    });
    await Promise.all([
      fetcher.get("https://a.example.org/1"),
      fetcher.get("https://a.example.org/2"),
      fetcher.get("https://a.example.org/3"),
      fetcher.get("https://b.example.org/1"),
    ]);
    const a = log.filter((l) => l.url.startsWith("https://a."));
    expect(a.filter((l) => l.url.endsWith("robots.txt"))).toHaveLength(1);
    for (let i = 1; i < a.length; i++)
      expect((a[i]?.at ?? 0) - (a[i - 1]?.at ?? 0)).toBeGreaterThanOrEqual(2000);
    expect(fetcher.requests.get("a.example.org")).toBe(4);
  });

  it("honours a longer Crawl-delay and refuses absurd ones", async () => {
    const { fetcher, log } = setup({
      "https://slow.example.org/robots.txt": { body: "User-agent: *\nCrawl-delay: 5\n" },
      "https://slow.example.org/1": { body: "1" },
      "https://slow.example.org/2": { body: "2" },
      "https://never.example.org/robots.txt": { body: "User-agent: *\nCrawl-delay: 3600\n" },
    });
    await fetcher.get("https://slow.example.org/1");
    await fetcher.get("https://slow.example.org/2");
    const s = log.filter((l) => !l.url.endsWith("robots.txt"));
    expect((s[1]?.at ?? 0) - (s[0]?.at ?? 0)).toBeGreaterThanOrEqual(5000);
    const never = await fetcher.get("https://never.example.org/x");
    expect(never).toMatchObject({ ok: false, reason: "crawl_delay_too_long" });
  });

  it("obeys robots.txt: Disallow, 5xx (disallow all) and 4xx (allow all)", async () => {
    const { fetcher, log } = setup({
      "https://a.example.org/robots.txt": OK_ROBOTS,
      "https://down.example.org/robots.txt": { status: 503 },
      "https://none.example.org/robots.txt": { status: 404 },
      "https://none.example.org/x": { body: "ok" },
    });
    expect(await fetcher.get("https://a.example.org/private/1")).toMatchObject({
      ok: false,
      reason: "robots_disallowed",
    });
    expect(await fetcher.get("https://down.example.org/x")).toMatchObject({
      ok: false,
      reason: "robots_unavailable",
    });
    expect((await fetcher.get("https://none.example.org/x")).ok).toBe(true);
    expect(log.some((l) => l.url === "https://a.example.org/private/1")).toBe(false);
  });

  it("never requests denylisted, login or non-https URLs, including through redirects", async () => {
    const { fetcher, log } = setup({
      "https://a.example.org/robots.txt": OK_ROBOTS,
      "https://a.example.org/go": {
        status: 302,
        headers: { location: "https://www.facebook.com/events/1" },
      },
      "https://a.example.org/gate": {
        status: 302,
        headers: { location: "/login?returnUrl=%2Fevents" },
      },
    });
    expect(await fetcher.get("https://www.eventbrite.com/e/1")).toMatchObject({
      ok: false,
      reason: "denylisted",
    });
    expect(await fetcher.get("http://a.example.org/events")).toMatchObject({
      ok: false,
      reason: "not_https",
    });
    expect(await fetcher.get("https://a.example.org/user/login")).toMatchObject({
      ok: false,
      reason: "login_page",
    });
    expect(await fetcher.get("https://a.example.org/go")).toMatchObject({
      ok: false,
      reason: "denylisted",
    });
    expect(await fetcher.get("https://a.example.org/gate")).toMatchObject({
      ok: false,
      reason: "login_page",
    });
    expect(log.some((l) => /facebook|eventbrite|login/.test(l.url))).toBe(false);
  });

  it("reports 401 and 403 as auth_required", async () => {
    const { fetcher } = setup({
      "https://a.example.org/robots.txt": OK_ROBOTS,
      "https://a.example.org/members": { status: 401 },
    });
    expect(await fetcher.get("https://a.example.org/members")).toMatchObject({
      ok: false,
      reason: "auth_required",
      status: 401,
    });
  });

  it("sends conditional GET headers and serves 304 from the cache", async () => {
    const cache = new MemoryHttpCache();
    let calls = 0;
    const route = (h: Record<string, string>): FakeResponse => {
      calls++;
      if (h["if-none-match"] === '"v1"') return { status: 304 };
      return {
        body: "BEGIN:VCALENDAR\nEND:VCALENDAR",
        headers: {
          etag: '"v1"',
          "last-modified": "Mon, 02 Nov 2026 00:00:00 GMT",
          "content-type": "text/calendar",
        },
      };
    };
    const { fetcher, log } = setup(
      { "https://a.example.org/robots.txt": OK_ROBOTS, "https://a.example.org/cal.ics": route },
      { cache },
    );
    const first = await fetcher.get("https://a.example.org/cal.ics");
    const second = await fetcher.get("https://a.example.org/cal.ics");
    expect(first).toMatchObject({ ok: true, notModified: false });
    expect(second).toMatchObject({
      ok: true,
      notModified: true,
      body: "BEGIN:VCALENDAR\nEND:VCALENDAR",
      contentType: "text/calendar",
    });
    const last = log.filter((l) => l.url.endsWith("cal.ics"))[1];
    expect(last?.headers["if-none-match"]).toBe('"v1"');
    expect(last?.headers["if-modified-since"]).toBe("Mon, 02 Nov 2026 00:00:00 GMT");
    expect(calls).toBe(2);
  });

  it("abandons bodies over the size cap and binary types", async () => {
    const { fetcher } = setup(
      {
        "https://a.example.org/robots.txt": OK_ROBOTS,
        "https://a.example.org/big": { body: "x".repeat(5000) },
        "https://a.example.org/declared": { body: "x", headers: { "content-length": "999999" } },
        "https://a.example.org/flyer": {
          body: "%PDF",
          headers: { "content-type": "application/pdf" },
        },
      },
      { maxBytes: 1000 },
    );
    expect(await fetcher.get("https://a.example.org/big")).toMatchObject({
      ok: false,
      reason: "too_large",
    });
    expect(await fetcher.get("https://a.example.org/declared")).toMatchObject({
      ok: false,
      reason: "too_large",
    });
    expect(await fetcher.get("https://a.example.org/flyer")).toMatchObject({
      ok: false,
      reason: "unsupported_type",
    });
  });

  it("turns transport timeouts into a timeout result", async () => {
    const c = fakeClock();
    const fetcher = new PoliteFetcher({
      denylist: deny,
      now: c.now,
      sleep: c.sleep,
      transport: async (url) => {
        if (url.endsWith("robots.txt")) return new Response("", { status: 404 });
        const err = new Error("timed out");
        err.name = "TimeoutError";
        throw err;
      },
    });
    expect(await fetcher.get("https://a.example.org/slow")).toMatchObject({
      ok: false,
      reason: "timeout",
    });
  });

  it("lets the API lane call official endpoints without robots.txt", async () => {
    const { fetcher, log } = setup({
      "https://api.seatgeek.com/2/events?client_id=x": { body: "{}" },
    });
    expect(
      (await fetcher.get("https://api.seatgeek.com/2/events?client_id=x", { api: true })).ok,
    ).toBe(true);
    expect(log.map((l) => l.url)).toEqual(["https://api.seatgeek.com/2/events?client_id=x"]);
    expect(await fetcher.get("https://api.seatgeek.com/2/events?client_id=x")).toMatchObject({
      reason: "denylisted",
    });
  });
});
