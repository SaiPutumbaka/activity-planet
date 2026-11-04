import { describe, expect, it } from "vitest";
import { type Candidate, dedupe, inAnyRegion, windowReason } from "../src/filter.ts";
import { normalize, type NormalizeContext } from "../src/normalize.ts";
import type { ImportItem, RawEvent } from "../src/types.ts";
import { ATL, NOW, WINDOW_END } from "./helpers.ts";

const ctx: NormalizeContext = {
  region: ATL,
  attribution: "Listed from a test calendar (example.org).",
};

function raw(over: Partial<RawEvent> = {}): RawEvent {
  return {
    lane: "feed",
    uid: "u1",
    title: "Community Clean-up",
    description: "Gloves provided.",
    url: "https://example.org/e/1",
    start: "2026-11-10T14:00:00Z",
    end: null,
    location: "Grant Park",
    lat: 33.7365,
    lng: -84.3708,
    sourceUrl: "https://example.org/feed.ics",
    ...over,
  };
}

function ok(r: ReturnType<typeof normalize>): ImportItem {
  if (!r.ok) throw new Error(`skipped: ${r.reason}`);
  return r.item;
}

describe("normalize: events constraints", () => {
  it("produces the import_upsert_batch item shape with attribution", () => {
    const item = ok(normalize(raw(), ctx));
    expect(item).toMatchObject({
      external_id: "u1",
      title: "Community Clean-up",
      starts_at: "2026-11-10T14:00:00.000Z",
      ends_at: "2026-11-10T16:00:00.000Z", // start + 2 h
      all_day: false,
      url: "https://example.org/e/1",
      cover_url: null,
      cancelled: false,
      attribution: ctx.attribution,
      lane: "feed",
      open_to_public: null,
    });
    expect(item.raw).toMatchObject({
      source_url: "https://example.org/feed.ics",
      zone_used: "America/New_York",
    });
  });

  it("collapses whitespace, clips titles at 120 and skips titles under 3", () => {
    expect(ok(normalize(raw({ title: "  Big \n\t Party  " }), ctx)).title).toBe("Big Party");
    const long = ok(normalize(raw({ title: "x".repeat(200) }), ctx)).title;
    expect(long).toHaveLength(120);
    expect(long.endsWith("…")).toBe(true);
    expect(normalize(raw({ title: " a " }), ctx)).toEqual({ ok: false, reason: "title_too_short" });
    expect(normalize(raw({ title: "<b>&amp;</b>" }), ctx)).toEqual({
      ok: false,
      reason: "title_too_short",
    });
  });

  it("keeps a description excerpt of at most 280 characters", () => {
    const d = ok(normalize(raw({ description: `${"word ".repeat(200)}end` }), ctx)).description;
    expect(d.length).toBeLessThanOrEqual(280);
    expect(d.endsWith("…")).toBe(true);
    expect(ok(normalize(raw({ description: "<p>Hi&nbsp;there</p>" }), ctx)).description).toBe(
      "Hi there",
    );
  });

  it("requires an https link, falling back to the listing page", () => {
    expect(normalize(raw({ url: "http://example.org/e/1" }), ctx)).toEqual({
      ok: false,
      reason: "no_https_url",
    });
    expect(normalize(raw({ url: null }), ctx)).toEqual({ ok: false, reason: "no_https_url" });
    expect(
      ok(normalize(raw({ url: null }), { ...ctx, fallbackUrl: "https://example.org/calendar" }))
        .url,
    ).toBe("https://example.org/calendar");
    expect(normalize(raw({ url: `https://example.org/${"a".repeat(2100)}` }), ctx).ok).toBe(false);
  });

  it("always sets ends_at and skips spans over 3 days", () => {
    expect(ok(normalize(raw({ end: "2026-11-10T13:00:00Z" }), ctx)).ends_at).toBe(
      "2026-11-10T16:00:00.000Z",
    );
    expect(ok(normalize(raw({ end: "2026-11-13T14:00:00Z" }), ctx)).ends_at).toBe(
      "2026-11-13T14:00:00.000Z",
    );
    expect(normalize(raw({ end: "2026-11-13T14:00:01Z" }), ctx)).toEqual({
      ok: false,
      reason: "longer_than_3_days",
    });
    expect(normalize(raw({ start: "soon" }), ctx)).toEqual({ ok: false, reason: "no_start" });
  });

  it("reads floating and date-only times in the region zone (or the source's)", () => {
    const floating = ok(
      normalize(raw({ start: "2026-11-15T08:00", end: "2026-11-15T09:00" }), ctx),
    );
    expect(floating.starts_at).toBe("2026-11-15T13:00:00.000Z");
    const allDay = ok(normalize(raw({ start: "2026-12-05", end: null }), ctx));
    expect(allDay).toMatchObject({
      all_day: true,
      starts_at: "2026-12-05T05:00:00.000Z",
      ends_at: "2026-12-06T04:59:00.000Z",
    });
    const multi = ok(normalize(raw({ start: "2026-12-05", end: "2026-12-06" }), ctx));
    expect(multi.ends_at).toBe("2026-12-07T04:59:00.000Z");
    const la = ok(
      normalize(raw({ start: "2026-11-15T08:00", timezone: "America/Los_Angeles" }), ctx),
    );
    expect(la.starts_at).toBe("2026-11-15T16:00:00.000Z");
  });

  it("clips location at 120, price at 40 and host at 120; uses Online for online events", () => {
    const item = ok(
      normalize(
        raw({ location: "L".repeat(300), priceText: "P".repeat(80), host: "H".repeat(200) }),
        ctx,
      ),
    );
    expect(item.location).toHaveLength(120);
    expect(item.price_text).toHaveLength(40);
    expect(item.host_org).toHaveLength(120);
    expect(
      ok(normalize(raw({ location: "", online: true, lat: null, lng: null }), ctx)).location,
    ).toBe("Online");
  });

  it("never sets cover_url unless the source licenses images", () => {
    expect(ok(normalize(raw({ imageUrl: "https://example.org/a.jpg" }), ctx)).cover_url).toBeNull();
    expect(
      ok(
        normalize(raw({ imageUrl: "https://example.org/a.jpg" }), { ...ctx, imagesLicensed: true }),
      ).cover_url,
    ).toBe("https://example.org/a.jpg");
  });

  it("keeps external ids within 200 characters and derives one when the source has none", () => {
    const long = ok(
      normalize(raw({ uid: "u".repeat(300) }), { ...ctx, idPrefix: "f1234:" }),
    ).external_id;
    expect(long.length).toBeLessThanOrEqual(200);
    expect(long.startsWith("f1234:h:")).toBe(true);
    expect(ok(normalize(raw({ uid: null }), ctx)).external_id).toBe(
      "https://example.org/e/1#2026-11-10T14:00:00.000Z",
    );
  });

  it("drops invalid points and postponed events, keeps cancelled ones flagged", () => {
    expect(ok(normalize(raw({ lat: 0, lng: 0 }), ctx)).lat).toBeNull();
    expect(ok(normalize(raw({ lat: 95, lng: 10 }), ctx)).lat).toBeNull();
    expect(normalize(raw({ postponed: true }), ctx)).toEqual({ ok: false, reason: "postponed" });
    expect(ok(normalize(raw({ cancelled: true }), ctx)).cancelled).toBe(true);
  });
});

describe("radius, window and dedupe", () => {
  const item = (over: Partial<RawEvent> = {}) => ok(normalize(raw(over), ctx));

  it("keeps points inside any region and items without a point", () => {
    expect(inAnyRegion(item(), [ATL])).toBe(true);
    expect(inAnyRegion(item({ lat: 34.5, lng: -84.388 }), [ATL])).toBe(false); // ~83 km north
    expect(
      inAnyRegion(item({ lat: 40.7128, lng: -74.006 }), [
        ATL,
        { ...ATL, id: "nyc", lat: 40.73, lng: -73.99, radiusKm: 20 },
      ]),
    ).toBe(true);
    expect(inAnyRegion(item({ lat: null, lng: null }), [ATL])).toBe(true);
  });

  it("drops ended and beyond-window items", () => {
    expect(windowReason(item({ start: "2026-11-01T14:00:00Z" }), NOW, WINDOW_END)).toBe("ended");
    expect(windowReason(item({ start: "2027-02-01T14:00:00Z" }), NOW, WINDOW_END)).toBe(
      "beyond_window",
    );
    expect(windowReason(item({ start: "2026-11-04T11:00:00Z" }), NOW, WINDOW_END)).toBeNull(); // still running
  });

  it("dedupes within a source by id, title+start or url+start, and keeps copies across sources", () => {
    const c = (sourceKey: string, i: ImportItem, order: number): Candidate => ({
      sourceKey,
      item: i,
      order,
    });
    const a = item();
    const { kept, dropped, notSent } = dedupe([
      c("page-src", { ...item({ lane: "page", uid: "p1" }) }, 0),
      c("feed-src", a, 1),
      c("feed-src", { ...a }, 1), // same id, same source
      c("api-src", item({ lane: "api", uid: "x9", title: "COMMUNITY  clean-up!" }), 2),
      c("api-src", item({ lane: "api", uid: "x8", title: "Community clean up" }), 2),
      c(
        "api-src",
        item({ lane: "api", uid: "x10", title: "Different", url: "https://example.org/e/1" }),
        2,
      ),
      c(
        "api-src",
        item({ lane: "api", uid: "x11", title: "Different", start: "2026-11-11T14:00:00Z" }),
        2,
      ),
    ]);
    // Cross-source copies are all sent (the database links them); within a source one is kept.
    expect(kept.map((k) => `${k.sourceKey}:${k.item.external_id}`)).toEqual([
      "page-src:p1",
      "feed-src:u1",
      "api-src:x9",
      "api-src:x11",
    ]);
    // x8: same title letters and start as x9; x10: same URL and start as x9.
    expect(Object.fromEntries(dropped)).toEqual({ "feed-src": 1, "api-src": 2 });
    // A dropped copy with its own id is reported, so the RPC still counts it as listed.
    expect(Object.fromEntries([...notSent].map(([k, v]) => [k, [...v]]))).toEqual({
      "api-src": ["x8", "x10"],
    });
  });

  it("prefers the copy with a point when lanes tie within a source", () => {
    const withPoint = item({ uid: "b" });
    const without = item({ uid: "a", lat: null, lng: null });
    const { kept } = dedupe([
      { sourceKey: "s1", item: without, order: 0 },
      { sourceKey: "s1", item: withPoint, order: 0 },
    ]);
    expect(kept.map((k) => k.item.external_id)).toEqual(["b"]);
  });
});
