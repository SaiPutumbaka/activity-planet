import { queryOptions } from "@tanstack/react-query";

import { supabase } from "./supabase";

/**
 * The moderator side of collector completion (migrations 62, 63 and 65; COLLECTOR_COMPLETION
 * Slice 2): listing removal requests (mod_listing_removal_queue, mod_listing_removal_resolve),
 * organizer claims (mod_organizer_claims, mod_organizer_claim_review) and the events section of
 * the health page (mod_collector_health). Moderators only: every RPC refuses anyone else.
 *
 *   parseCollectorHealth(raw)   // tolerant of missing keys, numbers coerced
 *   jobLabel("places_extract")  // "OpenStreetMap extract"
 */

export const collectorAdminKeys = {
  removals: (closed: boolean) => ["admin", "listing-removals", closed] as const,
  organizerClaims: (closed: boolean) => ["admin", "organizer-claims", closed] as const,
  health: ["admin", "collector-health"] as const,
};

// ---------------------------------------------------------------------------
// Listing removals
// ---------------------------------------------------------------------------

export interface ListingRemovalItem {
  id: string;
  reference: string;
  status: "open" | "removed" | "rejected";
  scope: "item" | "source";
  received_at: string;
  due_at: string;
  requester: { name: string; email: string; relationship: string };
  reason: string;
  url: string | null;
  event: {
    id: string;
    title: string;
    starts_at: string;
    external_url: string | null;
    moderation_state: string | null;
  } | null;
  source: {
    id: string;
    slug: string;
    name: string;
    url: string;
    enabled: boolean;
    origin: string;
  } | null;
  resolution_note: string;
  resolved_at: string | null;
}

export type ListingRemovalAction = "removed" | "rejected" | "reopen";

export const RELATIONSHIP_LABELS: Record<string, string> = {
  organizer: "the organizer",
  venue: "the venue",
  rights_holder: "a rights holder",
  other: "someone else",
};

/** What "Remove" does for this request's scope, before the moderator confirms. */
export function removalExplainer(item: Pick<ListingRemovalItem, "scope">): string {
  return item.scope === "source"
    ? "Removes everything the source listed, switches it off and stops the collector reading its site (shared calendar hosts stay readable for others)."
    : "Removes this listing for good, including copies from other sources.";
}

/** Whether the remove button can act: an item needs its event, a source its source. */
export function canRemove(item: Pick<ListingRemovalItem, "scope" | "event" | "source">): boolean {
  return item.scope === "source" ? item.source !== null : item.event !== null;
}

export const listingRemovalQueueQuery = (closed: boolean) =>
  queryOptions({
    queryKey: collectorAdminKeys.removals(closed),
    queryFn: async (): Promise<ListingRemovalItem[]> => {
      const { data, error } = await supabase.rpc("mod_listing_removal_queue", {
        p_limit: 100,
        p_closed: closed,
      });
      if (error) throw error;
      return (data ?? []) as unknown as ListingRemovalItem[];
    },
    staleTime: 15_000,
  });

export async function resolveListingRemoval(
  id: string,
  action: ListingRemovalAction,
  note?: string,
): Promise<void> {
  const { error } = await supabase.rpc("mod_listing_removal_resolve", {
    p_request: id,
    p_action: action,
    ...(note?.trim() ? { p_note: note.trim() } : {}),
  });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Organizer claims
// ---------------------------------------------------------------------------

export interface ModOrganizerClaim {
  id: string;
  status: "pending" | "verified" | "failed" | "revoked";
  method: "meta" | "well_known" | "dns_txt" | "feed";
  host: string;
  feed_url: string | null;
  attempts: number;
  failure: string | null;
  created_at: string;
  verified_at: string | null;
  reviewed_at: string | null;
  user: { id: string; handle: string; first_name: string } | null;
  source: {
    id: string;
    slug: string;
    name: string;
    url: string;
    origin: string;
    enabled: boolean;
  } | null;
  connected: number;
  can_act: boolean;
}

export const modOrganizerClaimsQuery = (closed: boolean) =>
  queryOptions({
    queryKey: collectorAdminKeys.organizerClaims(closed),
    queryFn: async (): Promise<ModOrganizerClaim[]> => {
      const { data, error } = await supabase.rpc("mod_organizer_claims", {
        p_closed: closed,
        p_limit: 100,
      });
      if (error) throw error;
      return (data ?? []) as unknown as ModOrganizerClaim[];
    },
    staleTime: 15_000,
  });

export async function reviewOrganizerClaim(
  id: string,
  action: "ok" | "revoke",
  note?: string,
): Promise<void> {
  const { error } = await supabase.rpc("mod_organizer_claim_review", {
    p_claim: id,
    p_action: action,
    ...(note?.trim() ? { p_note: note.trim() } : {}),
  });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Collector health
// ---------------------------------------------------------------------------

export const COLLECTOR_JOBS = [
  "ingest",
  "discovery",
  "verify",
  "places_extract",
  "places_files",
] as const;
export type CollectorJob = (typeof COLLECTOR_JOBS)[number];

const JOB_LABELS: Record<CollectorJob, string> = {
  ingest: "Nightly events read",
  discovery: "Source discovery",
  verify: "Organizer checks",
  places_extract: "OpenStreetMap extract",
  places_files: "Place files",
};

export function jobLabel(job: string): string {
  return JOB_LABELS[job as CollectorJob] ?? job;
}

export interface CollectorHealth {
  generatedAt: string;
  sources: { lane: string; state: string; count: number }[];
  stale: { slug: string; name: string; lane: string; hours: number }[];
  failing: { slug: string; name: string; lane: string; streak: number; error: string }[];
  jobs: { job: string; lastRun: string | null; outcome: string | null; overdue: boolean }[];
  regions: { total: number; behind: number };
  gate: { passed: boolean; at: string; ageDays: number; expired: boolean } | null;
  discovery7d: { outcome: string; count: number }[];
  geocoding: {
    upcoming: number;
    onCentroid: number;
    geocoded: number;
    cacheOk: number;
    cacheMiss: number;
    checked7d: number;
    nominatim: string;
  };
  budgets: { source: string; used: number; cap: number | null }[];
  removalsOpen: number;
  claims: { pending: number; verifiedUnreviewed: number };
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj =>
  v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {};
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const num = (v: unknown): number =>
  typeof v === "number" && Number.isFinite(v) ? v : Number(v) || 0;
const str = (v: unknown): string => (typeof v === "string" ? v : "");
const strOrNull = (v: unknown): string | null => (typeof v === "string" && v ? v : null);

export function parseCollectorHealth(raw: unknown): CollectorHealth {
  const h = obj(raw);
  const jobs = obj(h.jobs);
  const gate = h.gate && typeof h.gate === "object" ? obj(h.gate) : null;
  const geo = obj(h.geocoding);
  const claims = obj(h.claims);
  return {
    generatedAt: str(h.generated_at),
    sources: arr(h.sources).map((s) => {
      const o = obj(s);
      return { lane: str(o.lane), state: str(o.state), count: num(o.count) };
    }),
    stale: arr(h.stale).map((s) => {
      const o = obj(s);
      return { slug: str(o.slug), name: str(o.name), lane: str(o.lane), hours: num(o.hours) };
    }),
    failing: arr(h.failing).map((s) => {
      const o = obj(s);
      return {
        slug: str(o.slug),
        name: str(o.name),
        lane: str(o.lane),
        streak: num(o.streak),
        error: str(o.error),
      };
    }),
    jobs: [...new Set([...COLLECTOR_JOBS, ...Object.keys(jobs)])].map((job) => {
      const o = obj(jobs[job]);
      return {
        job,
        lastRun: strOrNull(o.last_run),
        outcome: strOrNull(o.outcome),
        overdue: o.overdue === true,
      };
    }),
    regions: { total: num(obj(h.regions).total), behind: num(obj(h.regions).behind) },
    gate: gate
      ? {
          passed: gate.passed === true,
          at: str(gate.at),
          ageDays: num(gate.age_days),
          expired: gate.expired === true,
        }
      : null,
    discovery7d: Object.entries(obj(h.discovery_7d))
      .map(([outcome, count]) => ({ outcome, count: num(count) }))
      .sort((a, b) => b.count - a.count || a.outcome.localeCompare(b.outcome)),
    geocoding: {
      upcoming: num(geo.upcoming),
      onCentroid: num(geo.on_centroid),
      geocoded: num(geo.geocoded),
      cacheOk: num(geo.cache_ok),
      cacheMiss: num(geo.cache_miss),
      checked7d: num(geo.checked_7d),
      nominatim: str(geo.nominatim) || "on",
    },
    budgets: Object.entries(obj(h.budgets))
      .map(([source, v]) => {
        const o = obj(v);
        return {
          source,
          used: num(o.used),
          cap: o.cap === null || o.cap === undefined ? null : num(o.cap),
        };
      })
      .sort((a, b) => a.source.localeCompare(b.source)),
    removalsOpen: num(h.removals_open),
    claims: { pending: num(claims.pending), verifiedUnreviewed: num(claims.verified_unreviewed) },
  };
}

/** How many upcoming imported events still sit on an area centroid, as a whole percentage. */
export function centroidShare(
  g: Pick<CollectorHealth["geocoding"], "upcoming" | "onCentroid">,
): number {
  return g.upcoming > 0 ? Math.round((g.onCentroid / g.upcoming) * 100) : 0;
}

export const collectorHealthQuery = () =>
  queryOptions({
    queryKey: collectorAdminKeys.health,
    queryFn: async (): Promise<CollectorHealth> => {
      const { data, error } = await supabase.rpc("mod_collector_health");
      if (error) throw error;
      return parseCollectorHealth(data);
    },
    staleTime: 60_000,
  });
