import type { AppSupabaseClient } from "../supabase/index";
import type { Database } from "../types/database";
import {
  bookingDetailSchema,
  bookingSummarySchema,
  bookingsPageSchema,
  cancelResultSchema,
  coachSchema,
  coachSearchRowSchema,
  coachingConfigSchema,
  parseRowsOf,
  payoutStatusSchema,
  requestBookingResultSchema,
  reviewsPageSchema,
  slotSchema,
  type AvailabilityException,
  type AvailabilityRule,
  type BookingCursor,
  type BookingDetail,
  type BookingSummary,
  type BookingsPage,
  type CancelResult,
  type Coach,
  type CoachSearchRow,
  type CoachStatus,
  type CoachingConfig,
  type ListingDelivery,
  type ListingStatus,
  type OwnListing,
  type PayoutStatus,
  type RequestBookingResult,
  type ReviewCursor,
  type ReviewsPage,
  type SearchCursor,
  type Slot,
} from "./schemas";

/**
 * Typed calls for the coaching RPCs (migration 60, design section 7). Every rule lives in the
 * database; these shape arguments, parse jsonb answers and throw the PostgREST error (its
 * message is the code, see errors.ts). The coach's own listings, availability and exceptions are
 * read straight from their tables (owner RLS); nothing is ever written to a table directly.
 *
 *   const coaching = createCoachingApi(supabase);
 *   await coaching.config();                   // { payments_enabled, policy_version, ... }
 *   await coaching.search({ delivery: "online" });
 *   await coaching.requestBooking({ listingId, startsAt, note, policyVersion, requestId });
 */

export interface CoachSearchParams {
  lat?: number | null;
  lng?: number | null;
  radiusKm?: number | null;
  hubId?: string | null;
  delivery?: ListingDelivery | null;
  query?: string | null;
  maxPriceMinor?: number | null;
  currency?: string | null;
  before?: SearchCursor | null;
  limit?: number;
}

export interface CoachProfileInput {
  headline?: string;
  about?: string;
  timezone?: string;
  in_person?: boolean;
  online?: boolean;
  lat?: number;
  lng?: number;
  radius_km?: number | null;
  area_label?: string;
}

export interface ListingInput {
  id?: string;
  title: string;
  description: string;
  delivery: ListingDelivery;
  format: "one_on_one" | "group";
  capacity: number;
  duration_minutes: number;
  price_minor: number;
  currency: string;
  buffer_minutes: number;
  min_notice_hours: number;
  max_advance_days: number;
  slot_step_minutes: number;
  auto_confirm: boolean;
  min_age: number;
  hub_id: string | null;
  meeting_note: string;
  online_link: string | null;
}

export interface CredentialInput {
  title: string;
  issuer: string;
  year: number | null;
}

/** Without null values: the RPCs' defaults stand in for anything left out. */
function compact(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(args)) if (v !== null && v !== undefined) out[k] = v;
  return out;
}

const OWN_LISTING_COLUMNS =
  "id,hub_id,title,description,delivery,format,capacity,duration_minutes,price_minor,currency,buffer_minutes,min_notice_hours,max_advance_days,slot_step_minutes,auto_confirm,min_age,status,moderation_state,coach_listing_private(meeting_note,online_link)";

export function createCoachingApi(client: AppSupabaseClient) {
  type RpcName = keyof Database["public"]["Functions"];
  async function rpc(fn: RpcName, args: Record<string, unknown> = {}): Promise<unknown> {
    // Names are checked against the generated types; arguments are shaped by each wrapper and
    // answers by the schemas (the generated types call jsonb `Json`).
    const { data, error } = await (
      client.rpc as unknown as (
        f: RpcName,
        a: Record<string, unknown>,
      ) => Promise<{ data: unknown; error: unknown }>
    )(fn, args);
    if (error) throw error;
    return data;
  }

  return {
    async config(): Promise<CoachingConfig> {
      return coachingConfigSchema.parse(await rpc("coaching_config"));
    },

    async search(p: CoachSearchParams = {}): Promise<CoachSearchRow[]> {
      const data = await rpc(
        "search_coaches",
        compact({
          p_lat: p.lat,
          p_lng: p.lng,
          p_radius_km: p.radiusKm,
          p_hub_id: p.hubId,
          p_delivery: p.delivery,
          p_query: p.query?.trim() ? p.query.trim() : null,
          p_max_price_minor: p.maxPriceMinor,
          p_currency: p.currency,
          p_before: p.before,
          p_limit: p.limit ?? 20,
        }),
      );
      return parseRowsOf(coachSearchRowSchema, data);
    },

    async getCoach(handle: string): Promise<Coach> {
      return coachSchema.parse(await rpc("get_coach", { p_handle: handle }));
    },

    async reviews(coachId: string, before?: ReviewCursor | null): Promise<ReviewsPage> {
      return reviewsPageSchema.parse(
        await rpc("coach_reviews_page", compact({ p_coach: coachId, p_before: before })),
      );
    },

    /** Bookable starts on the coach-local dates from..to (YYYY-MM-DD, at most 31 days). */
    async slots(listingId: string, fromDate: string, toDate: string): Promise<Slot[]> {
      const data = await rpc("coach_slots", {
        p_listing: listingId,
        p_from: fromDate,
        p_to: toDate,
      });
      return parseRowsOf(slotSchema, data);
    },

    async requestBooking(p: {
      listingId: string;
      startsAt: string;
      note: string;
      policyVersion: string;
      requestId: string;
    }): Promise<RequestBookingResult> {
      return requestBookingResultSchema.parse(
        await rpc("request_booking", {
          p_listing: p.listingId,
          p_starts_at: p.startsAt,
          p_note: p.note,
          p_policy_version: p.policyVersion,
          p_client_request_id: p.requestId,
        }),
      );
    },

    async getBooking(id: string): Promise<BookingDetail> {
      return bookingDetailSchema.parse(await rpc("get_booking", { p_id: id }));
    },

    async myBookings(
      role: "client" | "coach",
      scope: "upcoming" | "requests" | "past",
      before?: BookingCursor | null,
      limit = 30,
    ): Promise<BookingsPage> {
      return bookingsPageSchema.parse(
        await rpc(
          "my_bookings",
          compact({ p_role: role, p_scope: scope, p_before: before, p_limit: limit }),
        ),
      );
    },

    /** The next open booking with this person, for the DM header; null when none. */
    async bookingWith(userId: string): Promise<BookingSummary | null> {
      const data = await rpc("my_bookings_with", { p_user: userId });
      if (data == null) return null;
      const p = bookingSummarySchema.safeParse(data);
      return p.success ? p.data : null;
    },

    confirm: (id: string) => rpc("confirm_booking", { p_id: id }),
    decline: (id: string) => rpc("decline_booking", { p_id: id }),
    async cancel(id: string): Promise<CancelResult> {
      return cancelResultSchema.parse(await rpc("cancel_booking", { p_id: id }));
    },
    complete: (id: string) => rpc("complete_booking", { p_id: id }),
    markNoShow: (id: string) => rpc("mark_no_show", { p_id: id }),
    reportCoachNoShow: (id: string) => rpc("report_coach_no_show", { p_id: id }),
    contestNoShow: (id: string, note: string) => rpc("contest_no_show", { p_id: id, p_note: note }),
    setMeeting: (id: string, note: string, link: string | null) =>
      rpc("set_booking_meeting", { p_id: id, p_note: note, p_link: link ?? "" }),
    writeReview: (bookingId: string, rating: number, body: string) =>
      rpc("write_review", { p_booking: bookingId, p_rating: rating, p_body: body }),
    replyToReview: (bookingId: string, text: string) =>
      rpc("reply_to_review", { p_booking: bookingId, p_text: text }),

    /* Coach side ---------------------------------------------------- */

    /** The caller's coach profile status, or null when they have none. */
    async myCoachStatus(userId: string): Promise<CoachStatus | null> {
      const { data, error } = await client
        .from("coach_profiles")
        .select("user_id,status")
        .eq("user_id", userId)
        .maybeSingle();
      if (error) throw error;
      const row = data as { status?: CoachStatus } | null;
      return row?.status ?? null;
    },
    upsertProfile: (p: CoachProfileInput) => rpc("upsert_coach_profile", { p: compact({ ...p }) }),
    acceptTerms: (version: string) => rpc("accept_coach_terms", { p_version: version }),
    publish: () => rpc("publish_coach_profile"),
    pause: () => rpc("pause_coach_profile"),
    setCredentials: (list: CredentialInput[]) =>
      rpc("set_coach_credentials", {
        p: list.map((c) => compact({ title: c.title, issuer: c.issuer, year: c.year })),
      }),
    setPhotos: (urls: string[]) => rpc("set_coach_photos", { p_urls: urls }),
    setHubs: (hubIds: string[]) => rpc("set_coach_hubs", { p_hub_ids: hubIds }),

    async upsertListing(l: ListingInput): Promise<{ id: string; payable: boolean }> {
      const data = (await rpc("upsert_listing", {
        p: { ...l, online_link: l.online_link ?? "" },
      })) as { id: string; payable?: boolean };
      return { id: data.id, payable: Boolean(data.payable) };
    },
    setListingStatus: (id: string, status: ListingStatus) =>
      rpc("set_listing_status", { p_id: id, p_status: status }),

    async ownListings(userId: string): Promise<OwnListing[]> {
      const { data, error } = await client
        .from("coach_listings")
        .select(OWN_LISTING_COLUMNS)
        .eq("coach_id", userId)
        .order("created_at");
      if (error) throw error;
      return (
        (data ?? []) as unknown as (Omit<OwnListing, "meeting_note" | "online_link"> & {
          coach_listing_private:
            | { meeting_note: string; online_link: string | null }
            | { meeting_note: string; online_link: string | null }[]
            | null;
        })[]
      ).map(({ coach_listing_private: priv, ...l }) => {
        const p = Array.isArray(priv) ? priv[0] : priv;
        return { ...l, meeting_note: p?.meeting_note ?? "", online_link: p?.online_link ?? null };
      });
    },

    async ownAvailability(userId: string): Promise<AvailabilityRule[]> {
      const { data, error } = await client
        .from("coach_availability_rules")
        .select("weekday,start_local,end_local,listing_id")
        .eq("coach_id", userId)
        .order("weekday")
        .order("start_local");
      if (error) throw error;
      return (
        (data ?? []) as {
          weekday: number;
          start_local: string;
          end_local: string;
          listing_id: string | null;
        }[]
      ).map((r) => ({
        weekday: r.weekday,
        start: r.start_local.slice(0, 5),
        end: r.end_local.slice(0, 5),
        listing_id: r.listing_id,
      }));
    },
    setAvailability: (rules: AvailabilityRule[]) =>
      rpc("set_availability", {
        p_rules: rules.map((r) => compact({ ...r })),
      }),

    async ownExceptions(userId: string): Promise<AvailabilityException[]> {
      const { data, error } = await client
        .from("coach_availability_exceptions")
        .select("id,kind,starts_at,ends_at,note")
        .eq("coach_id", userId)
        .gte("ends_at", new Date().toISOString())
        .order("starts_at");
      if (error) throw error;
      return (data ?? []) as unknown as AvailabilityException[];
    },
    addException: (e: Omit<AvailabilityException, "id">) =>
      rpc("add_availability_exception", { p: e }) as Promise<string>,
    removeException: (id: string) => rpc("remove_availability_exception", { p_id: id }),

    scheduleGroupSession: (listingId: string, startsAt: string) =>
      rpc("schedule_group_session", { p_listing: listingId, p_starts_at: startsAt }),

    async payoutStatus(): Promise<PayoutStatus> {
      return payoutStatusSchema.parse(await rpc("coach_payout_status"));
    },

    /**
     * Stripe entry points (payments on only). The functions answer 503 payments_off without
     * their keys; the app never shows these controls unless coaching_config says payments are on.
     */
    async stripeConnect(
      op: "onboard" | "dashboard" | "refresh",
      country?: string,
    ): Promise<{
      url?: string;
    }> {
      const { data, error } = await client.functions.invoke("stripe-connect", {
        body: compact({ op, country }),
      });
      if (error) throw error;
      return (data ?? {}) as { url?: string };
    },
    async checkout(bookingId: string): Promise<{ url?: string }> {
      const { data, error } = await client.functions.invoke("stripe-checkout", {
        body: { op: "create", booking_id: bookingId },
      });
      if (error) throw error;
      return (data ?? {}) as { url?: string };
    },
  };
}

export type CoachingApi = ReturnType<typeof createCoachingApi>;
