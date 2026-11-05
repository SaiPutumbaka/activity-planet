import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

const { canRemove, centroidShare, jobLabel, parseCollectorHealth, removalExplainer } =
  await import("../collector-admin");
const { queueItemLink, queueItemTab } = await import("../admin");
const { notificationLink } = await import("../notifications");

describe("parseCollectorHealth", () => {
  it("reads the RPC's shape and fills every job", () => {
    const h = parseCollectorHealth({
      generated_at: "2026-11-05T12:00:00Z",
      sources: [{ lane: "feed", state: "enabled", count: 4 }],
      stale: [{ slug: "a", name: "A", lane: "feed", hours: 30 }],
      failing: [{ slug: "b", name: "B", lane: "page", streak: 3, error: "read_failed" }],
      jobs: {
        ingest: { last_run: "2026-11-04T03:00:00Z", outcome: "ok", overdue: false },
        verify: { last_run: null, overdue: false },
      },
      regions: { total: 5, behind: 1 },
      gate: { passed: true, at: "2026-11-01T00:00:00Z", age_days: 4, expired: false },
      discovery_7d: { good: 2, no_events_in_region: 9 },
      geocoding: { upcoming: 10, on_centroid: 4, geocoded: 6, cache_ok: 3, cache_miss: 1 },
      budgets: {
        geoapify_geocode: { used: 300, cap: 300 },
        ticketmaster_calls: { used: 2, cap: null },
      },
      removals_open: 2,
      claims: { pending: 1, verified_unreviewed: 0 },
    });
    expect(h.jobs.map((j) => j.job)).toEqual([
      "ingest",
      "discovery",
      "verify",
      "places_extract",
      "places_files",
    ]);
    expect(h.jobs[0]).toMatchObject({ lastRun: "2026-11-04T03:00:00Z", outcome: "ok" });
    expect(h.jobs[2]!.lastRun).toBeNull();
    expect(h.discovery7d[0]).toEqual({ outcome: "no_events_in_region", count: 9 });
    expect(h.budgets).toEqual([
      { source: "geoapify_geocode", used: 300, cap: 300 },
      { source: "ticketmaster_calls", used: 2, cap: null },
    ]);
    expect(centroidShare(h.geocoding)).toBe(40);
    expect(h.gate?.ageDays).toBe(4);
  });
  it("survives an empty answer", () => {
    const h = parseCollectorHealth(null);
    expect(h.stale).toEqual([]);
    expect(h.gate).toBeNull();
    expect(centroidShare(h.geocoding)).toBe(0);
    expect(h.geocoding.nominatim).toBe("on");
  });
});

describe("listing removals", () => {
  it("needs the event for an item and the source for a source", () => {
    expect(canRemove({ scope: "item", event: null, source: null })).toBe(false);
    expect(
      canRemove({
        scope: "source",
        event: null,
        source: {
          id: "s",
          slug: "s",
          name: "S",
          url: "https://x",
          enabled: true,
          origin: "collector",
        },
      }),
    ).toBe(true);
    expect(removalExplainer({ scope: "source" })).toContain("switches it off");
  });
});

describe("links into the new tabs", () => {
  it("opens listing removals and organizer claims on their tabs", () => {
    expect(queueItemLink({ source: "listing_removal" })).toBe("/admin/takedowns");
    expect(queueItemTab({ source: "listing_removal" })).toBe("listings");
    expect(queueItemLink({ source: "organizer_claim" })).toBe("/admin/claims");
    expect(queueItemTab({ source: "organizer_claim" })).toBe("organizers");
    expect(queueItemTab({ source: "report" })).toBeNull();
  });
  it("sends collector alerts to the Events health tab", () => {
    expect(
      notificationLink({
        kind: "collector_alert",
        event_id: null,
        payload: {},
        hub: null,
        chapter: null,
      }),
    ).toEqual({ to: "/admin/health", search: { tab: "events" } });
    expect(jobLabel("verify")).toBe("Organizer checks");
  });
});
