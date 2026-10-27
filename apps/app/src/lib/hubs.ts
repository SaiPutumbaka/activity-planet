import { queryOptions } from "@tanstack/react-query";
import type { Database } from "@ap/core/types";

import type { CatalogCategory, CatalogHub } from "./profile";
import { supabase } from "./supabase";

/**
 * Hubs tab and hub pages: queries, the membership writes, the search grouping and the error map.
 * Joining and leaving are direct writes on hub_members (migration 6, "Writes"); request_hub is the
 * only RPC. The catalog itself comes from lib/profile.ts (hubCatalogQuery, myHubsQuery).
 */

type Tables = Database["public"]["Tables"];
export type HubCategoryRow = Tables["hub_categories"]["Row"];
export type EventKind = Database["public"]["Enums"]["event_kind"];
export type EventStatus = Database["public"]["Enums"]["event_status"];
export type EventVisibility = Database["public"]["Enums"]["event_visibility"];

export const hubKeys = {
  memberCountsPrefix: ["hubs", "member-counts"] as const,
  memberCounts: (hubIds: readonly string[]) =>
    ["hubs", "member-counts", [...hubIds].sort()] as const,
  bySlug: (slug: string) => ["hubs", "by-slug", slug] as const,
  events: (hubId: string) => ["hubs", "events", hubId] as const,
  chapters: (hubId: string) => ["hubs", "chapters", hubId] as const,
  members: (hubId: string) => ["hubs", "members", hubId] as const,
  viewerAge: (userId: string) => ["viewer-age", userId] as const,
};

/* ------------------------------------------------------------------ */
/* Queries                                                              */
/* ------------------------------------------------------------------ */

/** hub id -> live member count, from hub_member_counts (one call per screen). */
export type MemberCounts = Record<string, number>;

export const hubMemberCountsQuery = (hubIds: readonly string[]) =>
  queryOptions({
    queryKey: hubKeys.memberCounts(hubIds),
    queryFn: async (): Promise<MemberCounts> => {
      if (hubIds.length === 0) return {};
      const { data, error } = await supabase.rpc("hub_member_counts", { p_hub_ids: [...hubIds] });
      if (error) throw error;
      const counts: MemberCounts = {};
      for (const row of data) counts[row.hub_id] = Number(row.members);
      return counts;
    },
    staleTime: 60_000,
  });

export interface HubPage {
  id: string;
  slug: string;
  name: string;
  category_slug: string;
  emoji: string;
  description: string;
  aliases: string[];
  scope: string;
  min_age: number;
  cover_url: string | null;
  is_featured: boolean;
  hub_categories: Pick<
    HubCategoryRow,
    "slug" | "name" | "color_key" | "is_sensitive" | "scope" | "min_age"
  > | null;
}

/** One hub with its category, for /hubs/$slug. Null when there is no active hub at that slug. */
export const hubBySlugQuery = (slug: string) =>
  queryOptions({
    queryKey: hubKeys.bySlug(slug),
    queryFn: async (): Promise<HubPage | null> => {
      const { data, error } = await supabase
        .from("hubs")
        .select(
          "id,slug,name,category_slug,emoji,description,aliases,scope,min_age,cover_url,is_featured,hub_categories(slug,name,color_key,is_sensitive,scope,min_age)",
        )
        .eq("slug", slug)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    staleTime: 5 * 60_000,
  });

export interface HubEvent {
  id: string;
  title: string;
  starts_at: string;
  ends_at: string;
  timezone: string;
  kind: EventKind;
  status: EventStatus;
  location_hint: string;
  going_count: number;
  capacity: number | null;
  min_age: number;
  visibility: EventVisibility;
  cover_url: string | null;
}

export const UPCOMING_WINDOW_DAYS = 30;

/**
 * Published events in the hub that have not ended yet and start within the window. RLS already
 * drops rows above the viewer's age and campus-only rows from other campuses.
 */
export const hubUpcomingEventsQuery = (hubId: string) =>
  queryOptions({
    queryKey: hubKeys.events(hubId),
    queryFn: async (): Promise<HubEvent[]> => {
      const now = new Date();
      const to = new Date(now.getTime() + UPCOMING_WINDOW_DAYS * 86_400_000);
      const { data, error } = await supabase
        .from("events")
        .select(
          "id,title,starts_at,ends_at,timezone,kind,status,location_hint,going_count,capacity,min_age,visibility,cover_url",
        )
        .eq("hub_id", hubId)
        .eq("status", "published")
        .gte("ends_at", now.toISOString())
        .lte("starts_at", to.toISOString())
        .order("starts_at")
        .limit(50);
      if (error) throw error;
      return data;
    },
    staleTime: 30_000,
  });

export interface HubChapter {
  id: string;
  slug: string;
  name: string;
  description: string;
  campus_id: string | null;
  org_campuses: { name: string } | null;
  /** PostgREST count aggregate: one element. Under-counts in sensitive categories (RLS). */
  chapter_members: { count: number }[];
}

export const hubChaptersQuery = (hubId: string) =>
  queryOptions({
    queryKey: hubKeys.chapters(hubId),
    queryFn: async (): Promise<HubChapter[]> => {
      const { data, error } = await supabase
        .from("hub_chapters")
        .select("id,slug,name,description,campus_id,org_campuses(name),chapter_members(count)")
        .eq("hub_id", hubId)
        .eq("is_active", true)
        .order("name");
      if (error) throw error;
      return data;
    },
    staleTime: 60_000,
  });

export interface HubMemberPreview {
  user_id: string;
  joined_at: string;
  profiles: { handle: string; first_name: string; avatar_url: string | null } | null;
}

export const MEMBER_PREVIEW_SIZE = 8;

/** The newest few members. In a sensitive category RLS returns only the viewer's own row. */
export const hubMembersPreviewQuery = (hubId: string) =>
  queryOptions({
    queryKey: hubKeys.members(hubId),
    queryFn: async (): Promise<HubMemberPreview[]> => {
      const { data, error } = await supabase
        .from("hub_members")
        .select("user_id,joined_at,profiles(handle,first_name,avatar_url)")
        .eq("hub_id", hubId)
        .order("joined_at", { ascending: false })
        .limit(MEMBER_PREVIEW_SIZE);
      if (error) throw error;
      return data;
    },
    staleTime: 60_000,
  });

/**
 * The viewer's age in whole years from viewer_age(); null before a birth date is recorded. Keyed
 * by user: the RPC answers for auth.uid(), so the next account on this device must not inherit it.
 */
export const viewerAgeQuery = (userId: string) =>
  queryOptions({
    queryKey: hubKeys.viewerAge(userId),
    queryFn: async (): Promise<number | null> => {
      const { data, error } = await supabase.rpc("viewer_age");
      if (error) throw error;
      return data ?? null;
    },
    staleTime: 60 * 60_000,
  });

/* ------------------------------------------------------------------ */
/* Writes                                                               */
/* ------------------------------------------------------------------ */

export async function joinHub(userId: string, hubId: string): Promise<void> {
  const { error } = await supabase.from("hub_members").insert({ user_id: userId, hub_id: hubId });
  // Already a member (a retried request, or two tabs) is the state we wanted.
  if (error && error.code !== "23505") throw error;
}

export async function leaveHub(userId: string, hubId: string): Promise<void> {
  const { error } = await supabase
    .from("hub_members")
    .delete()
    .eq("user_id", userId)
    .eq("hub_id", hubId);
  if (error) throw error;
}

export async function setHubNotify(userId: string, hubId: string, notify: boolean): Promise<void> {
  const { error } = await supabase
    .from("hub_members")
    .update({ notify })
    .eq("user_id", userId)
    .eq("hub_id", hubId);
  if (error) throw error;
}

export async function requestHub(name: string, note: string) {
  const { data, error } = await supabase.rpc("request_hub", { p_name: name, p_note: note });
  if (error) throw error;
  return data;
}

/* ------------------------------------------------------------------ */
/* Rules and helpers                                                    */
/* ------------------------------------------------------------------ */

export interface JoinRules {
  homeOrgId: string | null;
  /** From viewerAgeQuery; undefined while loading (no client-side block then, the server decides). */
  viewerAge: number | null | undefined;
}

/** Why the viewer cannot join this hub right now, as a sentence, or null when they can. */
export function joinBlockedReason(
  hub: { name: string; scope: string; min_age: number },
  rules: JoinRules,
): string | null {
  if (hub.scope === "campus" && !rules.homeOrgId) {
    return "Verify your campus email in You to join campus hubs.";
  }
  if (hub.min_age > 18 && rules.viewerAge != null && rules.viewerAge < hub.min_age) {
    return `${hub.name} is for people ${hub.min_age} and over.`;
  }
  return null;
}

export function formatMembers(count: number | undefined): string {
  if (count === undefined) return "";
  return count === 1 ? "1 member" : `${count} members`;
}

export function formatGoing(event: Pick<HubEvent, "going_count" | "capacity">): string {
  if (event.capacity !== null) return `${event.going_count} of ${event.capacity} going`;
  return event.going_count === 1 ? "1 going" : `${event.going_count} going`;
}

export function isFull(event: Pick<HubEvent, "going_count" | "capacity">): boolean {
  return event.capacity !== null && event.going_count >= event.capacity;
}

/** hub_categories.color_key -> one of the ten hub hues (dark text on a pale tint, board rule). */
const CATEGORY_TONES: Record<string, string> = {
  sport: "bg-hub-orange-bg text-hub-orange",
  endurance: "bg-hub-yellow-bg text-hub-yellow",
  wellness: "bg-hub-green-bg text-hub-green",
  outdoors: "bg-hub-lime-bg text-hub-lime",
  games: "bg-hub-indigo-bg text-hub-indigo",
  arts: "bg-hub-violet-bg text-hub-violet",
  food: "bg-hub-clay-bg text-hub-clay",
  fandom: "bg-hub-pink-bg text-hub-pink",
  learning: "bg-hub-sky-bg text-hub-sky",
  tech: "bg-hub-teal-bg text-hub-teal",
  social: "bg-hub-pink-bg text-hub-pink",
  nightlife: "bg-hub-violet-bg text-hub-violet",
};

export function categoryTone(colorKey: string | null | undefined): string {
  return (colorKey && CATEGORY_TONES[colorKey]) || "bg-surface-2 text-text-2";
}

/* ------------------------------------------------------------------ */
/* Search                                                               */
/* ------------------------------------------------------------------ */

export interface HubSection {
  category: CatalogCategory;
  hubs: CatalogHub[];
}

export function normalizeSearch(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

/** True when `needle` starts a word in `text` ("ping" matches "Ping pong", not "Camping"). */
function startsAWord(text: string, needle: string): boolean {
  const t = text.toLowerCase();
  let i = t.indexOf(needle);
  while (i !== -1) {
    if (i === 0 || !/[a-z0-9]/.test(t.charAt(i - 1))) return true;
    i = t.indexOf(needle, i + 1);
  }
  return false;
}

/**
 * Name, aliases and the category name all count. Every word of the (already normalized) needle
 * must start a word somewhere, so "table ten" finds Table Tennis and "ping" finds it through the
 * "ping pong" alias without dragging in Camping and Rapping.
 */
export function hubMatches(
  hub: Pick<CatalogHub, "name" | "aliases">,
  categoryName: string,
  needle: string,
): boolean {
  if (!needle) return true;
  const fields = [hub.name, ...hub.aliases, categoryName];
  return needle.split(" ").every((word) => fields.some((f) => startsAWord(f, word)));
}

/** The catalog grouped by category in catalog order, with hubs that match the search. */
export function groupHubsByCategory(
  catalog: { categories: CatalogCategory[]; hubs: CatalogHub[] } | undefined,
  needle: string,
): HubSection[] {
  if (!catalog) return [];
  const categoryNames = new Map(catalog.categories.map((c) => [c.slug, c.name]));
  const byCategory = new Map<string, CatalogHub[]>();
  for (const hub of catalog.hubs) {
    if (!hubMatches(hub, categoryNames.get(hub.category_slug) ?? "", needle)) continue;
    const list = byCategory.get(hub.category_slug) ?? [];
    list.push(hub);
    byCategory.set(hub.category_slug, list);
  }
  return catalog.categories
    .filter((c) => byCategory.has(c.slug))
    .map((c) => ({ category: c, hubs: byCategory.get(c.slug) ?? [] }));
}

/* ------------------------------------------------------------------ */
/* Errors                                                               */
/* ------------------------------------------------------------------ */

function errorParts(err: unknown): { message: string; code: string; hint: string } {
  if (typeof err === "object" && err !== null) {
    const o = err as Record<string, unknown>;
    return {
      message: typeof o.message === "string" ? o.message : "",
      code: typeof o.code === "string" ? o.code : "",
      hint: typeof o.hint === "string" ? o.hint : "",
    };
  }
  return { message: String(err ?? ""), code: "", hint: "" };
}

/** The slug request_hub puts in the hint of a hub_exists error, or null for any other error. */
export function existingHubSlug(err: unknown): string | null {
  const { message, hint } = errorParts(err);
  return message.includes("hub_exists") && hint ? hint : null;
}

const GENERIC = "Something went wrong. Try again.";

/**
 * Every error the Hubs screens can hit, as a sentence. RPC errors carry a snake_case code in
 * .message; the direct hub_members writes come back as PostgREST codes (23505 duplicate key,
 * 42501 row-level security, 23503 foreign key).
 */
export function hubErrorMessage(err: unknown, hub?: { name: string; min_age: number }): string {
  const { message, code } = errorParts(err);
  const name = hub?.name ?? "this hub";

  // request_hub
  if (message.includes("hub_exists")) return "That hub already exists.";
  if (message.includes("duplicate_request"))
    return "You already asked for this hub. It's in the queue.";
  if (message.includes("too_many_requests"))
    return "Up to three hub requests can be open at once. Wait for a review first.";
  if (message.includes("name_required")) return "Give the hub a name.";
  if (message.includes("name_length")) return "Hub names are 2 to 60 characters.";
  if (message.includes("note_too_long")) return "Keep the note under 280 characters.";
  if (message.includes("not_authenticated") || code === "PGRST301" || code === "401")
    return "Your session ended. Sign in again.";

  // hub_members
  if (code === "23505") return `You're already in ${name}.`;
  if (code === "42501" || message.includes("row-level security")) {
    return hub && hub.min_age > 18
      ? `${hub.name} is for people ${hub.min_age} and over.`
      : `You can't join ${name} right now.`;
  }
  if (code === "23503") return "That hub isn't around any more.";

  if (/Failed to fetch|NetworkError|Load failed|network/i.test(message))
    return "Check your connection and try again.";
  return GENERIC;
}
