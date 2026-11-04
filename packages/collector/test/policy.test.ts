import { describe, expect, it } from "vitest";
import { Denylist } from "../src/policy/denylist.ts";
import {
  isLoginUrl,
  looksLikeLoginPage,
  metaDirectives,
  parseXRobotsTag,
} from "../src/policy/meta.ts";
import { ALLOW_ALL, DISALLOW_ALL, parseRobots, robotsForStatus } from "../src/policy/robots.ts";

describe("robots.txt", () => {
  const robots = parseRobots(
    [
      "# comment",
      "User-agent: *",
      "Disallow: /private/",
      "Disallow: /*.pdf$",
      "Allow: /private/public-events/",
      "Crawl-delay: 1",
      "",
      "User-agent: Googlebot",
      "Disallow: /",
      "",
      "Sitemap: https://example.org/sitemap.xml",
    ].join("\n"),
  );

  it("uses the * group when there is no group for us", () => {
    expect(robots.isAllowed("https://example.org/events/")).toBe(true);
    expect(robots.isAllowed("https://example.org/private/x")).toBe(false);
  });
  it("lets the longest match win, Allow on a tie", () => {
    expect(robots.isAllowed("https://example.org/private/public-events/1")).toBe(true);
    const tie = parseRobots("User-agent: *\nDisallow: /a\nAllow: /a\n");
    expect(tie.isAllowed("https://example.org/a")).toBe(true);
  });
  it("supports * and $ wildcards", () => {
    expect(robots.isAllowed("https://example.org/files/flyer.pdf")).toBe(false);
    expect(robots.isAllowed("https://example.org/files/flyer.pdf?x=1")).toBe(true);
  });
  it("reads Crawl-delay", () => {
    expect(robots.crawlDelaySec).toBe(1);
  });
  it("prefers our own group, matched by product token", () => {
    const own = parseRobots(
      "User-agent: *\nDisallow: /\n\nUser-agent: ActivityPlanetBot\nUser-agent: OtherBot\nDisallow: /admin\n",
    );
    expect(own.isAllowed("https://example.org/events")).toBe(true);
    expect(own.isAllowed("https://example.org/admin/x")).toBe(false);
    const blocked = parseRobots("User-agent: activityplanetbot\nDisallow: /\n");
    expect(blocked.isAllowed("https://example.org/events")).toBe(false);
  });
  it("treats an empty Disallow as allow-all and robots.txt itself as allowed", () => {
    const r = parseRobots("User-agent: *\nDisallow:\n");
    expect(r.isAllowed("https://example.org/anything")).toBe(true);
    expect(DISALLOW_ALL.isAllowed("https://example.org/robots.txt")).toBe(false);
    expect(
      parseRobots("User-agent: *\nDisallow: /\n").isAllowed("https://example.org/robots.txt"),
    ).toBe(true);
  });
  it("maps statuses per RFC 9309: 4xx allow all, 5xx disallow all", () => {
    expect(robotsForStatus(404, "")).toBe(ALLOW_ALL);
    expect(robotsForStatus(403, "")).toBe(ALLOW_ALL);
    expect(robotsForStatus(503, "")).toBe(DISALLOW_ALL);
  });
});

describe("denylist (data/denylist.json)", () => {
  const deny = Denylist.load();

  it("blocks listed domains and their subdomains", () => {
    for (const url of [
      "https://www.facebook.com/events/1",
      "https://m.facebook.com/x",
      "https://instagram.com/p/1",
      "https://www.meetup.com/atl/events/1",
      "https://www.linkedin.com/events/1",
      "https://app.joinhandshake.com/events/1",
      "https://nextdoor.com/events/1",
      "https://x.com/a",
      "https://twitter.com/a",
      "https://www.tiktok.com/@a",
      "https://seatgeek.com/atlanta-united-tickets",
    ]) {
      expect(deny.check(url).denied, url).toBe(true);
    }
  });

  it("blocks eventbrite and ticketmaster under any suffix", () => {
    expect(deny.check("https://www.eventbrite.com/e/1").denied).toBe(true);
    expect(deny.check("https://www.eventbrite.co.uk/e/1").denied).toBe(true);
    expect(deny.check("https://eventbrite.ca/e/1").denied).toBe(true);
    expect(deny.check("https://www.ticketmaster.com/event/1").denied).toBe(true);
    expect(deny.check("https://www.ticketmaster.co.uk/event/1").denied).toBe(true);
  });

  it("lets only the API lane reach the official API endpoints", () => {
    const tm = "https://app.ticketmaster.com/discovery/v2/events.json?apikey=k";
    expect(deny.check(tm).denied).toBe(true);
    expect(deny.check(tm, { allowApi: true })).toEqual({ denied: false, api: true });
    expect(deny.check("https://api.seatgeek.com/2/events", { allowApi: true }).denied).toBe(false);
    expect(deny.check("https://app.ticketmaster.com/other", { allowApi: true }).denied).toBe(true);
  });

  it("does not over-match look-alike names", () => {
    expect(deny.check("https://notfacebook.com/").denied).toBe(false);
    expect(deny.check("https://facebook.com.example.org/").denied).toBe(false);
    expect(deny.check("https://eventbrite-alternatives.example.org/").denied).toBe(false);
    expect(deny.check("https://beltline.org/events/").denied).toBe(false);
  });
});

describe("noindex, nofollow and X-Robots-Tag", () => {
  it("reads robots meta tags for robots and our bot only", () => {
    expect(metaDirectives([{ name: "robots", content: "noindex, follow" }])).toMatchObject({
      noindex: true,
      nofollow: false,
    });
    expect(metaDirectives([{ name: "ROBOTS", content: "none" }])).toMatchObject({
      noindex: true,
      nofollow: true,
    });
    expect(metaDirectives([{ name: "activityplanetbot", content: "nofollow" }])).toMatchObject({
      noindex: false,
      nofollow: true,
    });
    expect(metaDirectives([{ name: "googlebot", content: "noindex" }])).toMatchObject({
      noindex: false,
      nofollow: false,
    });
  });
  it("reads X-Robots-Tag with and without bot prefixes", () => {
    expect(parseXRobotsTag("noindex")).toMatchObject({ noindex: true, nofollow: false });
    expect(parseXRobotsTag("googlebot: noindex, nofollow")).toMatchObject({
      noindex: false,
      nofollow: false,
    });
    expect(parseXRobotsTag("googlebot: noindex, ActivityPlanetBot: nofollow")).toMatchObject({
      noindex: false,
      nofollow: true,
    });
    expect(parseXRobotsTag("unavailable_after: 2027-01-01, noindex")).toMatchObject({
      noindex: true,
      nofollow: false,
    });
    expect(parseXRobotsTag(null)).toMatchObject({ noindex: false, nofollow: false });
  });
});

describe("login pages", () => {
  it("recognises login, sign-in and SSO URLs", () => {
    for (const url of [
      "https://example.org/login",
      "https://example.org/user/login?destination=/events",
      "https://example.org/users/sign_in",
      "https://login.example.org/",
      "https://sso.example.edu/idp/profile",
      "https://example.org/wp-login.php",
      "https://example.org/account/login/",
    ]) {
      expect(isLoginUrl(url), url).toBe(true);
    }
    for (const url of [
      "https://example.org/events/author-talk",
      "https://example.org/calendar?next=2",
      "https://example.org/events/",
    ]) {
      expect(isLoginUrl(url), url).toBe(false);
    }
  });
  it("recognises sign-in forms", () => {
    expect(
      looksLikeLoginPage('<form action="/session"><input type="password" name="p"></form>'),
    ).toBe(true);
    expect(looksLikeLoginPage('<form id="login-form"><input name="u"></form>')).toBe(true);
    expect(looksLikeLoginPage('<form action="/search"><input type="text"></form>')).toBe(false);
  });
});
