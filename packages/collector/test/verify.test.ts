import { describe, expect, it } from "vitest";
import { PoliteFetcher } from "../src/net/fetcher.ts";
import { Denylist } from "../src/policy/denylist.ts";
import {
  feedHasToken,
  pageHasToken,
  parseClaims,
  verifyClaim,
  wellKnownHasToken,
} from "../src/verify.ts";
import { fakeClock, fakeTransport, fixture, NOW, type FakeResponse } from "./helpers.ts";

const TOKEN = "ap-verify-abcdefghijklmnopqrstuvwx";
const ID = "0b9e7c1a-1111-4222-8333-944445555666";
const ROBOTS = { body: "User-agent: *\nAllow: /\n" };
const html = (body: string): FakeResponse => ({ body, headers: { "content-type": "text/html" } });

function setup(routes: Record<string, FakeResponse>, extra = {}) {
  const c = fakeClock();
  const { transport, log } = fakeTransport(routes, c.clock);
  return {
    fetcher: new PoliteFetcher({
      denylist: Denylist.load(),
      transport,
      now: c.now,
      sleep: c.sleep,
      ...extra,
    }),
    log,
  };
}

describe("ownership proofs", () => {
  it("finds the token in a meta tag, never in a comment or the text", () => {
    expect(pageHasToken(fixture("verify/home.html"), TOKEN)).toBe(true);
    expect(pageHasToken(fixture("verify/comment.html"), TOKEN)).toBe(false);
    expect(pageHasToken(fixture("verify/home.html"), "ap-verify-zzzzzzzzzzzzzzzzzzzzzzzz")).toBe(
      false,
    );
  });
  it("reads the .well-known file and the calendar description or an upcoming event", () => {
    expect(wellKnownHasToken(`${TOKEN}\n`, TOKEN)).toBe(true);
    expect(wellKnownHasToken(`x${TOKEN}`, TOKEN)).toBe(false);
    expect(feedHasToken(fixture("verify/connected.ics"), TOKEN, NOW)).toBe(true);
    // A folded DESCRIPTION of an upcoming event counts; a past one does not.
    expect(feedHasToken(fixture("verify/event-desc.ics"), TOKEN, NOW)).toBe(true);
    expect(
      feedHasToken(fixture("verify/event-desc.ics"), "ap-verify-zzzzzzzzzzzzzzzzzzzzzzzz", NOW),
    ).toBe(false);
  });
});

describe("verifyClaim through the PoliteFetcher", () => {
  it("verifies a meta tag on the home page after robots.txt", async () => {
    const { fetcher, log } = setup({
      "https://arts.example.org/robots.txt": ROBOTS,
      "https://arts.example.org/": html(fixture("verify/home.html")),
    });
    const r = await verifyClaim(
      {
        claim_id: ID,
        method: "meta",
        host: "arts.example.org",
        token: TOKEN,
        urls: ["https://arts.example.org/"],
      },
      fetcher,
      NOW,
    );
    expect(r).toEqual({ claim_id: ID, outcome: "verified", method: "meta" });
    expect(log.map((l) => l.url)).toEqual([
      "https://arts.example.org/robots.txt",
      "https://arts.example.org/",
    ]);
  });

  it("verifies the .well-known file, and a feed token", async () => {
    const wk = "https://arts.example.org/.well-known/activityplanet-verification.txt";
    const a = setup({
      "https://arts.example.org/robots.txt": ROBOTS,
      [wk]: { body: TOKEN, headers: { "content-type": "text/plain" } },
    });
    expect(
      (
        await verifyClaim(
          {
            claim_id: ID,
            method: "well_known",
            host: "arts.example.org",
            token: TOKEN,
            urls: [wk],
          },
          a.fetcher,
          NOW,
        )
      ).method,
    ).toBe("well_known");
    const feed = "https://calendar.example.com/ical/abc/public/basic.ics";
    const b = setup({
      "https://calendar.example.com/robots.txt": ROBOTS,
      [feed]: {
        body: fixture("verify/connected.ics"),
        headers: { "content-type": "text/calendar" },
      },
    });
    expect(
      await verifyClaim(
        { claim_id: ID, method: "feed", host: "calendar.example.com", token: TOKEN, urls: [feed] },
        b.fetcher,
        NOW,
      ),
    ).toEqual({
      claim_id: ID,
      outcome: "verified",
      method: "feed",
    });
  });

  it("does not count a token served after a redirect to another host", async () => {
    const { fetcher } = setup({
      "https://arts.example.org/robots.txt": ROBOTS,
      "https://arts.example.org/": {
        status: 301,
        headers: { location: "https://other.example.net/" },
      },
      "https://other.example.net/robots.txt": ROBOTS,
      "https://other.example.net/": html(fixture("verify/home.html")),
    });
    const r = await verifyClaim(
      {
        claim_id: ID,
        method: "meta",
        host: "arts.example.org",
        token: TOKEN,
        urls: ["https://arts.example.org/"],
      },
      fetcher,
      NOW,
    );
    expect(r).toEqual({ claim_id: ID, outcome: "fetch_failed", reason: "redirect_other_host" });
  });

  it("refuses private addresses and robots.txt refusals, and reads nothing over 3 MB", async () => {
    const priv = setup({});
    expect(
      await verifyClaim(
        {
          claim_id: ID,
          method: "meta",
          host: "127.0.0.1",
          token: TOKEN,
          urls: ["https://127.0.0.1/"],
        },
        priv.fetcher,
        NOW,
      ),
    ).toEqual({ claim_id: ID, outcome: "fetch_failed", reason: "private_address" });
    expect(priv.log).toHaveLength(0);
    const robots = setup({
      "https://arts.example.org/robots.txt": {
        body: "User-agent: ActivityPlanetBot\nDisallow: /\n",
      },
    });
    expect(
      await verifyClaim(
        {
          claim_id: ID,
          method: "meta",
          host: "arts.example.org",
          token: TOKEN,
          urls: ["https://arts.example.org/"],
        },
        robots.fetcher,
        NOW,
      ),
    ).toEqual({ claim_id: ID, outcome: "fetch_failed", reason: "robots_disallowed" });
    const big = setup({
      "https://arts.example.org/robots.txt": ROBOTS,
      "https://arts.example.org/": html(`<html>${"x".repeat(3_000_001)}</html>`),
    });
    expect(
      await verifyClaim(
        {
          claim_id: ID,
          method: "meta",
          host: "arts.example.org",
          token: TOKEN,
          urls: ["https://arts.example.org/"],
        },
        big.fetcher,
        NOW,
      ),
    ).toEqual({ claim_id: ID, outcome: "fetch_failed", reason: "too_large" });
  });

  it("reads at most 3 URLs, and a page without the token is token_not_found", async () => {
    const urls = ["/", "/a", "/b", "/c"].map((p) => `https://arts.example.org${p}`);
    const routes: Record<string, FakeResponse> = { "https://arts.example.org/robots.txt": ROBOTS };
    for (const u of urls) routes[u] = html("<html><head></head></html>");
    const { fetcher, log } = setup(routes);
    expect(
      await verifyClaim(
        { claim_id: ID, method: "meta", host: "arts.example.org", token: TOKEN, urls },
        fetcher,
        NOW,
      ),
    ).toEqual({
      claim_id: ID,
      outcome: "token_not_found",
    });
    expect(log.filter((l) => !l.url.endsWith("robots.txt"))).toHaveLength(3);
  });

  it("drops malformed queue entries", () => {
    expect(
      parseClaims({
        claims: [
          {
            claim_id: ID,
            method: "meta",
            host: "arts.example.org",
            token: TOKEN,
            urls: ["https://arts.example.org/", "http://x"],
          },
          { claim_id: ID, method: "dns_txt", host: "a.org", token: TOKEN, urls: [] },
          { claim_id: "x", method: "meta", host: "a.org", token: TOKEN, urls: [] },
        ],
      }),
    ).toEqual([
      {
        claim_id: ID,
        method: "meta",
        host: "arts.example.org",
        token: TOKEN,
        urls: ["https://arts.example.org/"],
      },
    ]);
  });
});
