import {
  queryOptions,
  useMutation,
  useQuery,
  useQueryClient,
  type QueryClient,
  type QueryKey,
} from "@tanstack/react-query";
import { toast } from "sonner";
import {
  parseRecPrefs,
  parseRows,
  recCoachSchema,
  recEventSchema,
  recHubSchema,
  recPersonSchema,
  type RecCoach,
  type RecEvent,
  type RecHub,
  type RecPerson,
  type RecPrefs,
} from "@ap/core/recs";
import { deviceTimeZone } from "@ap/core/feed";
import type { Database } from "@ap/core/types";

import { feedPrefsQuery, useFeedOrigin } from "./location";
import { supabase } from "./supabase";

/**
 * Recommendations (D-045, RECS_DESIGN slice 2). Every row re-ranks something the viewer can
 * already see (feed_events_v2, search_coaches, shared context), so these are plain invoker RPCs.
 * The rows come from the feed's origin (the device point only after "Use my location", else the
 * saved home, which the server reads itself) and the radius the feed settled on.
 *
 *   useQuery(recsForYouQuery({ userId, point, homeKey, areaId, radiusKm, timeZone }))
 *   useQuery(recsSimilarQuery(eventId, origin))
 *   const dismiss = useDismissRec(); dismiss.mutate({ kind: "event", id })   // optimistic
 *   useQuery(recPrefsQuery(userId)); await setRecPrefs({ personalize: false })
 */

export type RecSubjectKind = Database["public"]["Enums"]["rec_subject_kind"];

const STALE = 5 * 60_000;

export interface RecOrigin {
  userId: string;
  /** The rounded device point, only when the person tapped "Use my location". */
  point: { lat: number; lng: number } | null;
  /** The saved home area or point, part of the key only (the server reads profile_private). */
  areaId?: string | null;
  homeKey?: string | null;
  /** The radius the feed used (after widening), in km. */
  radiusKm?: number | null;
  /** The device's IANA zone, for Tonight / Tomorrow chips. */
  timeZone?: string | null;
}

/**
 * The feed's origin outside Home (event page, Hubs, Coaches): the device point when in use, else
 * the saved home, at the saved radius.
 */
export function useRecOrigin(userId: string): RecOrigin {
  const origin = useFeedOrigin(userId);
  const prefs = useQuery(feedPrefsQuery(userId));
  return {
    userId,
    point: origin.point,
    areaId: origin.homeArea?.id ?? null,
    homeKey: origin.homePoint
      ? `${origin.homePoint.lat},${origin.homePoint.lng}`
      : (origin.homeLabel ?? null),
    radiusKm: prefs.data?.radiusKm ?? null,
    timeZone: deviceTimeZone(),
  };
}

function originKey(o: RecOrigin) {
  return {
    lat: o.point?.lat ?? null,
    lng: o.point?.lng ?? null,
    areaId: o.areaId ?? null,
    home: o.homeKey ?? null,
    radiusKm: o.radiusKm ?? null,
    timeZone: o.timeZone ?? null,
  };
}

function originArgs(o: RecOrigin) {
  return {
    ...(o.point ? { p_lat: o.point.lat, p_lng: o.point.lng } : {}),
    ...(o.radiusKm ? { p_radius_km: o.radiusKm } : {}),
  };
}

/** For you on Home: at least three plans, or none (the server returns none under three). */
export const recsForYouQuery = (o: RecOrigin) =>
  queryOptions({
    queryKey: ["recs", "for-you", o.userId, originKey(o)] as const,
    queryFn: async (): Promise<RecEvent[]> => {
      const { data, error } = await supabase.rpc("recs_for_you", {
        ...originArgs(o),
        ...(o.timeZone ? { p_timezone: o.timeZone } : {}),
        p_limit: 10,
      });
      if (error) throw error;
      return parseRows(recEventSchema, data);
    },
    staleTime: STALE,
  });

/** Similar plans on an event page. Not personal: shown with personalization off too. */
export const recsSimilarQuery = (eventId: string, o: RecOrigin) =>
  queryOptions({
    queryKey: ["recs", "similar", o.userId, eventId, originKey(o)] as const,
    queryFn: async (): Promise<RecEvent[]> => {
      const { data, error } = await supabase.rpc("recs_similar_events", {
        p_event_id: eventId,
        ...originArgs(o),
        ...(o.timeZone ? { p_timezone: o.timeZone } : {}),
        p_limit: 6,
      });
      if (error) throw error;
      return parseRows(recEventSchema, data);
    },
    staleTime: STALE,
  });

export const recsHubsQuery = (o: RecOrigin, limit = 8) =>
  queryOptions({
    queryKey: ["recs", "hubs", o.userId, originKey(o), limit] as const,
    queryFn: async (): Promise<RecHub[]> => {
      const { data, error } = await supabase.rpc("recs_hubs", { ...originArgs(o), p_limit: limit });
      if (error) throw error;
      return parseRows(recHubSchema, data);
    },
    staleTime: STALE,
  });

export const recsCoachesQuery = (o: RecOrigin) =>
  queryOptions({
    queryKey: ["recs", "coaches", o.userId, originKey(o)] as const,
    queryFn: async (): Promise<RecCoach[]> => {
      const { data, error } = await supabase.rpc("recs_coaches", { ...originArgs(o), p_limit: 6 });
      if (error) throw error;
      return parseRows(recCoachSchema, data);
    },
    staleTime: STALE,
  });

export const recsPeopleQuery = (userId: string) =>
  queryOptions({
    queryKey: ["recs", "people", userId] as const,
    queryFn: async (): Promise<RecPerson[]> => {
      const { data, error } = await supabase.rpc("recs_people", { p_limit: 8 });
      if (error) throw error;
      return parseRows(recPersonSchema, data);
    },
    staleTime: STALE,
  });

/* ------------------------------------------------------------------ */
/* Not interested                                                       */
/* ------------------------------------------------------------------ */

type RecRow = RecEvent | RecHub | RecCoach | RecPerson;

/** The subject id of a row of any kind (events and hubs by id; coaches and people by user). */
function rowId(row: RecRow): string {
  return "user_id" in row ? row.user_id : row.id;
}

export async function dismissRec(kind: RecSubjectKind, id: string): Promise<void> {
  const { error } = await supabase.rpc("rec_dismiss", { p_kind: kind, p_id: id });
  if (error) throw error;
}

export async function undismissRec(kind: RecSubjectKind, id: string): Promise<void> {
  const { error } = await supabase.rpc("rec_undismiss", { p_kind: kind, p_id: id });
  if (error) throw error;
}

function removeEverywhere(qc: QueryClient, id: string): [QueryKey, unknown][] {
  const snapshots = qc.getQueriesData<RecRow[]>({ queryKey: ["recs"] });
  for (const [key, rows] of snapshots) {
    if (!Array.isArray(rows)) continue;
    qc.setQueryData<RecRow[]>(
      key,
      rows.filter((r) => rowId(r) !== id),
    );
  }
  return snapshots;
}

export function dismissErrorMessage(err: unknown): string {
  const msg = err && typeof err === "object" && "message" in err ? String(err.message) : "";
  if (msg.includes("rate_limited")) return "That's a lot at once. Try again in a while.";
  return "Couldn't save that. Try again.";
}

/**
 * "Not interested": the card leaves every recommendation row at once and comes back if the
 * call fails. The toast offers Undo.
 */
export function useDismissRec() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ kind, id }: { kind: RecSubjectKind; id: string }) => dismissRec(kind, id),
    onMutate: async ({ id }) => {
      await qc.cancelQueries({ queryKey: ["recs"] });
      return { snapshots: removeEverywhere(qc, id) };
    },
    onError: (err, _vars, ctx) => {
      for (const [key, rows] of ctx?.snapshots ?? []) qc.setQueryData(key, rows);
      toast.error(dismissErrorMessage(err));
    },
    onSuccess: (_data, { kind, id }) => {
      toast("We'll show you fewer like this.", {
        action: {
          label: "Undo",
          onClick: () => {
            void undismissRec(kind, id)
              .then(() => qc.invalidateQueries({ queryKey: ["recs"] }))
              .catch(() => toast.error("Couldn't undo that. Try again."));
          },
        },
      });
    },
  });
}

/* ------------------------------------------------------------------ */
/* Preferences (You, Privacy and safety)                                */
/* ------------------------------------------------------------------ */

export const recPrefsQuery = (userId: string) =>
  queryOptions({
    queryKey: ["rec-prefs", userId] as const,
    queryFn: async (): Promise<RecPrefs> => {
      const { data, error } = await supabase.rpc("my_recommendation_prefs");
      if (error) throw error;
      return parseRecPrefs(data);
    },
    staleTime: STALE,
  });

export async function setRecPrefs(patch: Partial<RecPrefs>): Promise<RecPrefs> {
  const { data, error } = await supabase.rpc("set_recommendation_prefs", {
    ...(patch.personalize !== undefined ? { p_personalize: patch.personalize } : {}),
    ...(patch.people_suggestions !== undefined
      ? { p_people_suggestions: patch.people_suggestions }
      : {}),
  });
  if (error) throw error;
  return parseRecPrefs(data);
}

export function useSetRecPrefs(userId: string) {
  const qc = useQueryClient();
  const key = recPrefsQuery(userId).queryKey;
  return useMutation({
    mutationFn: setRecPrefs,
    onMutate: async (patch) => {
      await qc.cancelQueries({ queryKey: key });
      const before = qc.getQueryData<RecPrefs>(key);
      if (before) qc.setQueryData<RecPrefs>(key, { ...before, ...patch });
      return { before };
    },
    onError: (_err, _patch, ctx) => {
      if (ctx?.before) qc.setQueryData(key, ctx.before);
      toast.error("Couldn't save that. Try again.");
    },
    onSuccess: (prefs) => {
      qc.setQueryData(key, prefs);
      void qc.invalidateQueries({ queryKey: ["recs"] });
    },
  });
}
