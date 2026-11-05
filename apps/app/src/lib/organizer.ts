import { queryOptions } from "@tanstack/react-query";
import type { ClaimMethod, OrganizerClaim } from "@ap/core/organizer";

import { supabase } from "./supabase";

/**
 * Organizer claims and connected calendars (migrations 62 and 65; COLLECTOR_COMPLETION 2.2 to
 * 2.4 and 2.8). Reads my_organizer_claims, organizer_claim_target and organizer_source_detail,
 * and acts through start_organizer_claim, organizer_claim_check (or the organizer-verify Edge
 * Function for the DNS proof, which it checks at once), organizer_source_update and
 * connect_organizer_feed. Eventbrite goes through the eventbrite-connect Edge Function, which
 * answers {available: false} until its keys exist, so the button stays hidden. Every rule is
 * the database's; nothing here decides who owns what.
 */

export const organizerKeys = {
  all: ["organizer"] as const,
  claims: ["organizer", "claims"] as const,
  target: (eventId: string) => ["organizer", "target", eventId] as const,
  source: (id: string) => ["organizer", "source", id] as const,
  eventbrite: ["organizer", "eventbrite"] as const,
};

export interface ClaimTarget {
  source_name: string;
  source_kind: string;
  origin: string;
  hosts: string[];
  feed_url: string | null;
  claimed: boolean;
  mine: boolean;
  source_id: string | null;
}

export interface SourceItem {
  event_id: string;
  title: string;
  starts_at: string;
  status: string;
  hidden: boolean;
}

export interface SourceDetail {
  id: string;
  name: string;
  kind: string;
  origin: string;
  url: string | null;
  homepage_url: string | null;
  enabled: boolean;
  stopped: boolean;
  verified: boolean;
  can_manage: boolean;
  default_hub: string | null;
  images_licensed: boolean;
  refresh_requested_at: string | null;
  last_ok_at: string | null;
  collector_seen_at: string | null;
  has_error: boolean;
  items: SourceItem[];
}

export interface StartedClaim {
  claim_id: string;
  status: string;
  method: ClaimMethod;
  host: string;
  token: string;
}

export const myClaimsQuery = () =>
  queryOptions({
    queryKey: organizerKeys.claims,
    queryFn: async (): Promise<OrganizerClaim[]> => {
      const { data, error } = await supabase.rpc("my_organizer_claims");
      if (error) throw error;
      return (data ?? []) as unknown as OrganizerClaim[];
    },
    staleTime: 15_000,
  });

export const claimTargetQuery = (eventId: string | null) =>
  queryOptions({
    queryKey: organizerKeys.target(eventId ?? ""),
    queryFn: async (): Promise<ClaimTarget> => {
      const { data, error } = await supabase.rpc("organizer_claim_target", { p_event: eventId! });
      if (error) throw error;
      return data as unknown as ClaimTarget;
    },
    enabled: Boolean(eventId),
    staleTime: 60_000,
    retry: false,
  });

export const sourceDetailQuery = (id: string) =>
  queryOptions({
    queryKey: organizerKeys.source(id),
    queryFn: async (): Promise<SourceDetail> => {
      const { data, error } = await supabase.rpc("organizer_source_detail", { p_source: id });
      if (error) throw error;
      return data as unknown as SourceDetail;
    },
    staleTime: 15_000,
    retry: false,
  });

export async function startClaim(input: {
  eventId: string | null;
  host: string | null;
  method: ClaimMethod;
  feedUrl?: string | null;
}): Promise<StartedClaim> {
  const { data, error } = await supabase.rpc("start_organizer_claim", {
    ...(input.eventId ? { p_event: input.eventId } : {}),
    ...(input.host ? { p_host: input.host } : {}),
    p_method: input.method,
    ...(input.feedUrl ? { p_feed_url: input.feedUrl } : {}),
  });
  if (error) throw error;
  return data as unknown as StartedClaim;
}

export type CheckOutcome = "verified" | "queued" | "not_yet" | "resolver_error" | "closed";

/** "Check now": the DNS proof is looked up at once; the others go to the next verify run. */
export async function checkClaim(
  claim: Pick<OrganizerClaim, "claim_id" | "method">,
): Promise<CheckOutcome> {
  if (claim.method === "dns_txt") {
    const { data, error } = await supabase.functions.invoke<{
      status?: string;
      checked?: string;
      error?: string;
    }>("organizer-verify", { method: "POST", body: { claim_id: claim.claim_id } });
    if (error) throw new Error("check_failed");
    if (data?.status === "verified") return "verified";
    if (data?.status && data.status !== "pending") return "closed";
    return data?.checked === "resolver_error" ? "resolver_error" : "not_yet";
  }
  const { error } = await supabase.rpc("organizer_claim_check", { p_claim: claim.claim_id });
  if (error) throw error;
  return "queued";
}

export async function updateSource(id: string, args: Record<string, unknown>): Promise<void> {
  const { error } = await supabase.rpc("organizer_source_update", {
    p_source: id,
    p_args: args as never,
  });
  if (error) throw error;
}

export async function connectFeed(
  url: string,
  claimId: string,
  point?: { lat: number; lng: number } | null,
): Promise<{ source_id: string; created: boolean }> {
  const { data, error } = await supabase.rpc("connect_organizer_feed", {
    p_url: url,
    p_claim: claimId,
    ...(point ? { p_lat: point.lat, p_lng: point.lng } : {}),
  });
  if (error) throw error;
  return data as unknown as { source_id: string; created: boolean };
}

/** Whether the server has Eventbrite keys; false on any error, so the button stays hidden. */
export const eventbriteStatusQuery = () =>
  queryOptions({
    queryKey: organizerKeys.eventbrite,
    queryFn: async (): Promise<boolean> => {
      try {
        const { data, error } = await supabase.functions.invoke<{ available?: boolean }>(
          "eventbrite-connect",
          { method: "POST", body: { op: "status" } },
        );
        return !error && data?.available === true;
      } catch {
        return false;
      }
    },
    staleTime: 10 * 60_000,
    retry: false,
  });

export async function eventbriteStart(): Promise<string> {
  const { data, error } = await supabase.functions.invoke<{ url?: string; skipped?: string }>(
    "eventbrite-connect",
    { method: "POST", body: { op: "start" } },
  );
  if (error || !data?.url || !/^https:\/\/www\.eventbrite\.com\//.test(data.url)) {
    throw new Error(data?.skipped ? "eventbrite_off" : "connect_failed");
  }
  return data.url;
}

export async function eventbriteCallback(code: string, state: string): Promise<void> {
  const { data, error } = await supabase.functions.invoke<{ connected?: boolean; error?: string }>(
    "eventbrite-connect",
    { method: "POST", body: { op: "callback", code, state } },
  );
  if (error || data?.connected !== true) throw new Error(data?.error ?? "connect_failed");
}

/** The device's location, coarse, only when the person taps (D-036): a region for a feed. */
export function coarsePosition(): Promise<{ lat: number; lng: number }> {
  return new Promise((resolve, reject) => {
    if (!("geolocation" in navigator)) {
      reject(new Error("no_location"));
      return;
    }
    navigator.geolocation.getCurrentPosition(
      (p) =>
        resolve({
          lat: Math.round(p.coords.latitude * 10) / 10,
          lng: Math.round(p.coords.longitude * 10) / 10,
        }),
      () => reject(new Error("no_location")),
      { enableHighAccuracy: false, maximumAge: 10 * 60_000, timeout: 15_000 },
    );
  });
}
