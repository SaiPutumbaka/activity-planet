import { infiniteQueryOptions, queryOptions, useQuery } from "@tanstack/react-query";
import {
  createCoachingApi,
  type BookingCursor,
  type BookingsPage,
  type CoachSearchParams,
  type CoachSearchRow,
  type SearchCursor,
} from "@ap/core/coaching";

import { supabase } from "./supabase";

/**
 * Coaching in the app (D-044, design section 15 slice 2). The typed calls, schemas, previews and
 * copy are in @ap/core/coaching; this file holds the query keys and options.
 *
 *   useCoachingConfig()                                // payments on? policy and terms versions
 *   useQuery(coachQuery(handle))                       // get_coach
 *   useInfiniteQuery(coachSearchQuery(params))         // search_coaches, keyset pages
 *   useQuery(slotsQuery(listingId, from, to))          // coach_slots (server-side)
 *   useInfiniteQuery(myBookingsQuery(role, scope))     // my_bookings
 *   useQuery(bookingQuery(id))                         // get_booking
 *
 * Every payment control is behind config.payments_enabled and the listing's payable flag; with
 * payments off (the default, "requests only") none renders.
 */

export const coaching = createCoachingApi(supabase);

export const coachingKeys = {
  all: ["coaching"] as const,
  config: ["coaching", "config"] as const,
  status: (userId: string) => ["coaching", "status", userId] as const,
  coach: (handle: string) => ["coaching", "coach", handle.toLowerCase()] as const,
  search: (p: CoachSearchParams) => ["coaching", "search", p] as const,
  slots: (listingId: string, from: string, to: string) =>
    ["coaching", "slots", listingId, from, to] as const,
  bookings: (role: string, scope: string) => ["coaching", "bookings", role, scope] as const,
  booking: (id: string) => ["coaching", "booking", id] as const,
  with: (userId: string) => ["coaching", "with", userId] as const,
  ownListings: (userId: string) => ["coaching", "own-listings", userId] as const,
  availability: (userId: string) => ["coaching", "availability", userId] as const,
  exceptions: (userId: string) => ["coaching", "exceptions", userId] as const,
  payouts: ["coaching", "payouts"] as const,
};

export const coachingConfigQuery = queryOptions({
  queryKey: coachingKeys.config,
  queryFn: () => coaching.config(),
  staleTime: 5 * 60_000,
});

/** coaching_config(); payments stay off (requests only) until it says otherwise. */
export function useCoachingConfig() {
  const q = useQuery(coachingConfigQuery);
  return { ...q, paymentsEnabled: q.data?.payments_enabled === true };
}

/** The viewer's own coach profile status, or null when they don't coach. */
export const myCoachStatusQuery = (userId: string) =>
  queryOptions({
    queryKey: coachingKeys.status(userId),
    queryFn: () => coaching.myCoachStatus(userId),
    staleTime: 60_000,
  });

const notFound = (err: unknown) => /not_found/.test(String((err as Error)?.message));

export const coachQuery = (handle: string) =>
  queryOptions({
    queryKey: coachingKeys.coach(handle),
    queryFn: () => coaching.getCoach(handle),
    staleTime: 30_000,
    retry: (count, err) => count < 1 && !notFound(err),
  });

export const SEARCH_PAGE = 20;

export const coachSearchQuery = (p: CoachSearchParams) =>
  infiniteQueryOptions({
    queryKey: coachingKeys.search(p),
    queryFn: ({ pageParam }) => coaching.search({ ...p, before: pageParam, limit: SEARCH_PAGE }),
    initialPageParam: null as SearchCursor | null,
    getNextPageParam: (last: CoachSearchRow[]) =>
      last.length < SEARCH_PAGE ? null : (last[last.length - 1]?.page_key ?? null),
    staleTime: 30_000,
  });

export const slotsQuery = (listingId: string, from: string, to: string) =>
  queryOptions({
    queryKey: coachingKeys.slots(listingId, from, to),
    queryFn: () => coaching.slots(listingId, from, to),
    staleTime: 15_000,
  });

export type BookingRole = "client" | "coach";
export type BookingScope = "upcoming" | "requests" | "past";

export const myBookingsQuery = (role: BookingRole, scope: BookingScope) =>
  infiniteQueryOptions({
    queryKey: coachingKeys.bookings(role, scope),
    queryFn: ({ pageParam }) => coaching.myBookings(role, scope, pageParam),
    initialPageParam: null as BookingCursor | null,
    getNextPageParam: (last: BookingsPage) => last.next,
    staleTime: 15_000,
  });

export const bookingQuery = (id: string) =>
  queryOptions({
    queryKey: coachingKeys.booking(id),
    queryFn: () => coaching.getBooking(id),
    staleTime: 10_000,
    retry: (count, err) => count < 1 && !notFound(err),
  });

export const bookingWithQuery = (userId: string) =>
  queryOptions({
    queryKey: coachingKeys.with(userId),
    queryFn: () => coaching.bookingWith(userId),
    staleTime: 60_000,
  });

export const ownListingsQuery = (userId: string) =>
  queryOptions({
    queryKey: coachingKeys.ownListings(userId),
    queryFn: () => coaching.ownListings(userId),
    staleTime: 30_000,
  });

export const availabilityQuery = (userId: string) =>
  queryOptions({
    queryKey: coachingKeys.availability(userId),
    queryFn: () => coaching.ownAvailability(userId),
    staleTime: 30_000,
  });

export const exceptionsQuery = (userId: string) =>
  queryOptions({
    queryKey: coachingKeys.exceptions(userId),
    queryFn: () => coaching.ownExceptions(userId),
    staleTime: 30_000,
  });

export const payoutStatusQuery = queryOptions({
  queryKey: coachingKeys.payouts,
  queryFn: () => coaching.payoutStatus(),
  staleTime: 30_000,
});

/** The site's DRAFT policy pages (apps/web), linked wherever someone commits. */
export function coachTermsUrl(site: string) {
  return `${site}/coach-terms`;
}
export function refundPolicyUrl(site: string) {
  return `${site}/refund-policy`;
}

/** Common IANA zones for the coach's zone picker, plus whatever the device and profile use. */
export function zoneOptions(...extra: (string | null | undefined)[]): string[] {
  let all: string[];
  try {
    all =
      (Intl as unknown as { supportedValuesOf?: (k: string) => string[] }).supportedValuesOf?.(
        "timeZone",
      ) ?? [];
  } catch {
    all = [];
  }
  const set = new Set<string>([...extra.filter((z): z is string => Boolean(z)), ...all, "UTC"]);
  return [...set];
}
