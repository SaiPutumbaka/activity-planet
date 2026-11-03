import { queryOptions } from "@tanstack/react-query";
import { z } from "zod";
import type { Database, Json } from "@ap/core/types";

import type { HubEvent } from "./hubs";
import { supabase } from "./supabase";

/**
 * Chapters (PLAN.md 4.5, D-035): a hub at one organization (a campus club, a rec league) or in
 * one neighborhood. Claims, members, roles, the "can I manage this" checks, the public card and
 * the error map. Every write goes through an RPC from migration 16 except joining and leaving,
 * which are direct writes on chapter_members (RLS: anyone may join an area chapter, an
 * organization's chapter needs a verified membership in it).
 *
 *   useQuery(chapterBySlugQuery(slug))         // the chapter page
 *   useQuery(myManagedChaptersQuery(userId))   // "Post as" and the You tab row
 *   useQuery(myChapterClaimsQuery(userId))     // claim status in the claim sheet
 *   await submitChapterClaim(toClaimArgs(values, place))
 *   chapterErrorMessage(err)                   // "This chapter already has an organizer."
 */

export type ChapterRole = Database["public"]["Enums"]["chapter_role"];
export type ClaimStatus = Database["public"]["Enums"]["chapter_claim_status"];
type Functions = Database["public"]["Functions"];
export type MyClaim = Functions["my_chapter_claims"]["Returns"][number];
type ManagedChapterRow = Functions["my_managed_chapters"]["Returns"][number];

/** Bumped when the Captain Program agreement text changes; stored on every claim. */
export const CLAIM_AGREEMENT_VERSION = "2026-11";

export const chapterKeys = {
  all: ["chapters"] as const,
  bySlug: (slug: string) => ["chapters", "by-slug", slug] as const,
  members: (chapterId: string) => ["chapters", "members", chapterId] as const,
  events: (chapterId: string) => ["chapters", "events", chapterId] as const,
  managed: (userId: string) => ["chapters", "managed", userId] as const,
  claims: (userId: string) => ["chapters", "claims", userId] as const,
  pendingClaims: ["chapters", "pending-claims"] as const,
  isModerator: (userId: string) => ["is-moderator", userId] as const,
};

/* ------------------------------------------------------------------ */
/* Queries                                                              */
/* ------------------------------------------------------------------ */

const CHAPTER_SELECT =
  "id,slug,name,description,cover_url,hub_id,org_id,campus_id,area_id,rso_name,pin_url,verified_at,is_active,hubs(id,slug,name,emoji,min_age,scope,is_active),organizations(name,slug),org_campuses(name,slug),areas(name,slug)" as const;

/** One active chapter with its hub and place. Null when there is none at that slug. */
export const chapterBySlugQuery = (slug: string) =>
  queryOptions({
    queryKey: chapterKeys.bySlug(slug),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("hub_chapters")
        .select(CHAPTER_SELECT)
        .eq("slug", slug)
        .eq("is_active", true)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    staleTime: 60_000,
  });

export type ChapterDetail = NonNullable<
  Awaited<ReturnType<NonNullable<ReturnType<typeof chapterBySlugQuery>["queryFn"]>>>
>;

/** Everyone in the chapter, organizers first. In a sensitive hub RLS returns only the viewer's row. */
export const chapterMembersQuery = (chapterId: string) =>
  queryOptions({
    queryKey: chapterKeys.members(chapterId),
    queryFn: async (): Promise<ChapterMember[]> => {
      const { data, error } = await supabase
        .from("chapter_members")
        .select("user_id,role,joined_at,profiles(handle,first_name,avatar_url)")
        .eq("chapter_id", chapterId)
        .order("joined_at")
        .limit(500);
      if (error) throw error;
      return sortMembers(data);
    },
    staleTime: 30_000,
  });

export interface ChapterMember {
  user_id: string;
  role: ChapterRole;
  joined_at: string;
  profiles: { handle: string; first_name: string; avatar_url: string | null } | null;
}

/** The chapter's published plans that have not ended, soonest first. */
export const chapterUpcomingEventsQuery = (chapterId: string) =>
  queryOptions({
    queryKey: chapterKeys.events(chapterId),
    queryFn: async (): Promise<HubEvent[]> => {
      const { data, error } = await supabase
        .from("events")
        .select(
          "id,title,starts_at,ends_at,timezone,kind,status,location_hint,going_count,capacity,min_age,visibility,cover_url",
        )
        .eq("chapter_id", chapterId)
        .eq("status", "published")
        .gte("ends_at", new Date().toISOString())
        .order("starts_at")
        .limit(30);
      if (error) throw error;
      return data;
    },
    staleTime: 30_000,
  });

export interface PostAsHub {
  id: string;
  slug: string;
  name: string;
  emoji: string;
  min_age: number;
  scope: string;
  is_active: boolean;
}

export interface ManagedChapter {
  id: string;
  slug: string;
  name: string;
  role: ChapterRole;
  hubId: string;
  campusId: string | null;
  placeLabel: string;
  isActive: boolean;
  /** The chapter's hub with the fields the post form needs; null when it is not readable. */
  hub: PostAsHub | null;
}

/** Chapters where the viewer is a captain or organizer, each with its hub. */
export const myManagedChaptersQuery = (userId: string) =>
  queryOptions({
    queryKey: chapterKeys.managed(userId),
    queryFn: async (): Promise<ManagedChapter[]> => {
      const { data, error } = await supabase.rpc("my_managed_chapters");
      if (error) throw error;
      const hubIds = [...new Set(data.map((c) => c.hub_id))];
      let hubs: PostAsHub[] = [];
      if (hubIds.length > 0) {
        const res = await supabase
          .from("hubs")
          .select("id,slug,name,emoji,min_age,scope,is_active")
          .in("id", hubIds);
        if (res.error) throw res.error;
        hubs = res.data;
      }
      return toManagedChapters(data, hubs);
    },
    staleTime: 60_000,
  });

/** The viewer's claims, newest first. */
export const myChapterClaimsQuery = (userId: string) =>
  queryOptions({
    queryKey: chapterKeys.claims(userId),
    queryFn: async (): Promise<MyClaim[]> => {
      const { data, error } = await supabase.rpc("my_chapter_claims");
      if (error) throw error;
      return data;
    },
    staleTime: 30_000,
  });

/** is_moderator() for the signed-in account. Keyed by user so the next account does not inherit it. */
export const isModeratorQuery = (userId: string) =>
  queryOptions({
    queryKey: chapterKeys.isModerator(userId),
    queryFn: async (): Promise<boolean> => {
      const { data, error } = await supabase.rpc("is_moderator");
      if (error) throw error;
      return data === true;
    },
    staleTime: 5 * 60_000,
  });

/** Pending claims for the moderator queue (RLS shows every claim to moderators only). */
export const pendingClaimsQuery = () =>
  queryOptions({
    queryKey: chapterKeys.pendingClaims,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("chapter_claims")
        .select(
          "id,kind,user_id,hub_id,chapter_id,proposed_name,rso_name,pin_url,officer_role_text,reference_name,reference_contact,motivation,created_at,hubs(slug,name,emoji),organizations(name),org_campuses(name),areas(name),profiles!chapter_claims_user_id_fkey(handle,first_name)",
        )
        .eq("status", "pending")
        .order("created_at")
        .limit(100);
      if (error) throw error;
      return data;
    },
    staleTime: 15_000,
  });

export type PendingClaim = Awaited<
  ReturnType<NonNullable<ReturnType<typeof pendingClaimsQuery>["queryFn"]>>
>[number];

/** The logged-out chapter card (chapter_public_card): nothing personal. */
export const chapterPublicCardQuery = (slugOrId: string) =>
  queryOptions({
    queryKey: ["chapters", "public-card", slugOrId] as const,
    queryFn: async (): Promise<ChapterPublicCard | null> => {
      const { data, error } = await supabase.rpc("chapter_public_card", { p_chapter: slugOrId });
      if (error) throw error;
      return parsePublicCard(data);
    },
    staleTime: 5 * 60_000,
  });

/* ------------------------------------------------------------------ */
/* Writes                                                               */
/* ------------------------------------------------------------------ */

/** submit_chapter_claim(p_args). Keys absent from the object are not sent. */
export type ClaimArgs = {
  kind: "org" | "area";
  hub_id: string;
  chapter_id?: string;
  org_id?: string;
  campus_id?: string;
  area_id?: string;
  proposed_name?: string;
  rso_name?: string;
  pin_url?: string;
  officer_role_text?: string;
  reference_name?: string;
  reference_contact?: string;
  motivation?: string;
  agreement_version: string;
};

export async function submitChapterClaim(args: ClaimArgs) {
  const { data, error } = await supabase.rpc("submit_chapter_claim", { p_args: args as Json });
  if (error) throw error;
  return data;
}

export async function withdrawChapterClaim(claimId: string) {
  const { data, error } = await supabase.rpc("withdraw_chapter_claim", { p_claim_id: claimId });
  if (error) throw error;
  return data;
}

export async function reviewChapterClaim(claimId: string, approve: boolean, note: string) {
  const trimmed = note.trim();
  const { data, error } = await supabase.rpc("review_chapter_claim", {
    p_claim_id: claimId,
    p_approve: approve,
    ...(trimmed ? { p_note: trimmed } : {}),
  });
  if (error) throw error;
  return data;
}

export async function setChapterRole(chapterId: string, userId: string, role: ChapterRole) {
  const { error } = await supabase.rpc("set_chapter_role", {
    p_chapter: chapterId,
    p_user: userId,
    p_role: role,
  });
  if (error) throw error;
}

export async function removeChapterMember(chapterId: string, userId: string) {
  const { error } = await supabase.rpc("remove_chapter_member", {
    p_chapter: chapterId,
    p_user: userId,
  });
  if (error) throw error;
}

export async function joinChapter(userId: string, chapterId: string): Promise<void> {
  const { error } = await supabase
    .from("chapter_members")
    .insert({ user_id: userId, chapter_id: chapterId });
  // Already in (a retried request, or two tabs) is the state we wanted.
  if (error && error.code !== "23505") throw error;
}

export async function leaveChapter(userId: string, chapterId: string): Promise<void> {
  const { error } = await supabase
    .from("chapter_members")
    .delete()
    .eq("user_id", userId)
    .eq("chapter_id", chapterId);
  if (error) throw error;
}

/* ------------------------------------------------------------------ */
/* Pure mappers and rules                                               */
/* ------------------------------------------------------------------ */

const ROLE_ORDER: Record<ChapterRole, number> = { organizer: 0, captain: 1, member: 2 };

/** Organizers, then captains, then members; oldest first within a role. */
export function sortMembers<T extends { role: ChapterRole; joined_at: string }>(rows: T[]): T[] {
  return [...rows].sort(
    (a, b) => ROLE_ORDER[a.role] - ROLE_ORDER[b.role] || a.joined_at.localeCompare(b.joined_at),
  );
}

export function roleLabel(role: ChapterRole): string {
  switch (role) {
    case "organizer":
      return "Organizer";
    case "captain":
      return "Captain";
    default:
      return "Member";
  }
}

export function canManageChapter(role: ChapterRole | null | undefined, isModerator: boolean) {
  return isModerator || role === "organizer" || role === "captain";
}

export interface MemberActions {
  /** Roles the viewer may set on this member (excluding the current one). */
  roles: ChapterRole[];
  canRemove: boolean;
}

/**
 * What the viewer may do to one member, mirroring set_chapter_role and remove_chapter_member
 * (the server decides for real): organizers set member or captain on non-organizers and may step
 * down themselves; only moderators grant organizer or change another organizer; captains remove
 * members and captains, never an organizer; the last organizer stays.
 */
export function memberActions(opts: {
  viewerId: string;
  viewerRole: ChapterRole | null;
  isModerator: boolean;
  target: { user_id: string; role: ChapterRole };
  organizerCount: number;
}): MemberActions {
  const { viewerId, viewerRole, isModerator, target, organizerCount } = opts;
  const self = target.user_id === viewerId;
  const lastOrganizer = target.role === "organizer" && organizerCount <= 1;
  const all: ChapterRole[] = ["member", "captain", "organizer"];

  let roles: ChapterRole[] = [];
  if (isModerator) {
    roles = all;
  } else if (viewerRole === "organizer") {
    if (target.role !== "organizer") roles = ["member", "captain"];
    else if (self) roles = ["member", "captain"];
  }
  roles = roles.filter((r) => r !== target.role && !(lastOrganizer && r !== "organizer"));

  let canRemove = false;
  if (!self && !lastOrganizer) {
    if (isModerator) canRemove = true;
    else if (viewerRole === "organizer") canRemove = target.role !== "organizer";
    else if (viewerRole === "captain") canRemove = target.role !== "organizer";
  }
  return { roles, canRemove };
}

/** The row my_managed_chapters returns, joined to its hub, as the post form and You tab use it. */
export function toManagedChapters(
  rows: ManagedChapterRow[],
  hubs: readonly PostAsHub[],
): ManagedChapter[] {
  const byId = new Map(hubs.map((h) => [h.id, h]));
  return rows
    .filter((r) => r.is_active)
    .map((r) => ({
      id: r.chapter_id,
      slug: r.slug,
      name: r.name,
      role: r.role,
      hubId: r.hub_id,
      // Typed string by the generator, null at runtime for an area chapter.
      campusId: r.campus_id || null,
      placeLabel: r.place_label || "",
      isActive: r.is_active,
      hub: byId.get(r.hub_id) ?? null,
    }));
}

/** The name of the place a chapter belongs to: campus, then organization, then area. */
export function chapterPlaceLabel(chapter: {
  org_campuses?: { name: string } | null;
  organizations?: { name: string } | null;
  areas?: { name: string } | null;
}): string {
  return chapter.org_campuses?.name ?? chapter.organizations?.name ?? chapter.areas?.name ?? "";
}

/**
 * The not-affiliated line belongs only on surfaces that name Georgia State (D-022, D-035): a
 * chapter whose organization or campus is Georgia State. Area chapters never carry it.
 */
export function isGsuBranded(...names: (string | null | undefined)[]): boolean {
  return names.some((n) => /georgia state|\bgsu\b/i.test(n ?? ""));
}

export const GSU_DISCLAIMER = "Not affiliated with or endorsed by Georgia State University.";

export interface ClaimStatusView {
  label: string;
  tone: "going" | "warning" | "danger" | "info";
}

export function claimStatusView(status: ClaimStatus): ClaimStatusView {
  switch (status) {
    case "pending":
      return { label: "In review", tone: "warning" };
    case "approved":
      return { label: "Approved", tone: "going" };
    case "rejected":
      return { label: "Not approved", tone: "danger" };
    default:
      return { label: "Withdrawn", tone: "info" };
  }
}

/* ------------------------------------------------------------------ */
/* Claim form                                                           */
/* ------------------------------------------------------------------ */

const optionalText = (max: number, message: string) => z.string().trim().max(max, message);

export const claimFormSchema = z
  .object({
    kind: z.enum(["org", "area"]),
    areaId: z.string(),
    proposedName: z.string().trim(),
    rsoName: optionalText(120, "Keep the group name under 120 characters."),
    pinUrl: optionalText(500, "Keep the link under 500 characters."),
    officerRole: optionalText(80, "Keep your role under 80 characters."),
    referenceName: optionalText(80, "Keep the name under 80 characters."),
    referenceContact: optionalText(200, "Keep the contact under 200 characters."),
    motivation: optionalText(1000, "Keep this under 1,000 characters."),
    agreed: z.boolean(),
  })
  .superRefine((v, ctx) => {
    if (v.kind === "area" && !v.areaId) {
      ctx.addIssue({ code: "custom", path: ["areaId"], message: "Pick a neighborhood." });
    }
    if (v.proposedName && (v.proposedName.length < 2 || v.proposedName.length > 100)) {
      ctx.addIssue({
        code: "custom",
        path: ["proposedName"],
        message: "Chapter names are 2 to 100 characters.",
      });
    }
    if (v.rsoName && v.rsoName.length < 2) {
      ctx.addIssue({ code: "custom", path: ["rsoName"], message: "At least 2 characters." });
    }
    if (v.pinUrl && !/^https:\/\/\S+$/.test(v.pinUrl)) {
      ctx.addIssue({ code: "custom", path: ["pinUrl"], message: "Links start with https://." });
    }
    if (!v.agreed) {
      ctx.addIssue({
        code: "custom",
        path: ["agreed"],
        message: "Agree to the captain guidelines to send the claim.",
      });
    }
  });

export type ClaimFormValues = z.infer<typeof claimFormSchema>;
export type ClaimFormField = keyof ClaimFormValues;

export function emptyClaimForm(kind: "org" | "area"): ClaimFormValues {
  return {
    kind,
    areaId: "",
    proposedName: "",
    rsoName: "",
    pinUrl: "",
    officerRole: "",
    referenceName: "",
    referenceContact: "",
    motivation: "",
    agreed: false,
  };
}

/** The first message per field from a failed parse, for showing under each control. */
export function claimFormErrors(
  values: ClaimFormValues,
): Partial<Record<ClaimFormField, string>> | null {
  const parsed = claimFormSchema.safeParse(values);
  if (parsed.success) return null;
  const errors: Partial<Record<ClaimFormField, string>> = {};
  for (const issue of parsed.error.issues) {
    const key = issue.path[0] as ClaimFormField | undefined;
    if (key && !errors[key]) errors[key] = issue.message;
  }
  return errors;
}

/** Where the claim is for: an existing chapter, the viewer's verified organization, or an area. */
export interface ClaimPlace {
  hubId: string;
  chapterId?: string | null;
  orgId?: string | null;
  campusId?: string | null;
}

/**
 * submit_chapter_claim arguments from the form. Empty strings are left out (the RPC trims and
 * nulls them anyway); an existing chapter fixes the place, so only its id goes; org fields are
 * dropped from an area claim and the area from an org claim.
 */
export function toClaimArgs(v: ClaimFormValues, place: ClaimPlace): ClaimArgs {
  const args: ClaimArgs = {
    kind: v.kind,
    hub_id: place.hubId,
    agreement_version: CLAIM_AGREEMENT_VERSION,
  };
  const put = (key: keyof ClaimArgs, value: string | null | undefined) => {
    const trimmed = value?.trim();
    if (trimmed) (args as Record<string, string>)[key] = trimmed;
  };
  if (place.chapterId) {
    put("chapter_id", place.chapterId);
  } else if (v.kind === "org") {
    put("org_id", place.orgId);
    put("campus_id", place.campusId);
  } else {
    put("area_id", v.areaId);
  }
  put("proposed_name", v.proposedName);
  if (v.kind === "org") {
    put("rso_name", v.rsoName);
    put("pin_url", v.pinUrl);
    put("officer_role_text", v.officerRole);
  }
  put("reference_name", v.referenceName);
  put("reference_contact", v.referenceContact);
  put("motivation", v.motivation);
  return args;
}

/* ------------------------------------------------------------------ */
/* Public card                                                          */
/* ------------------------------------------------------------------ */

export interface ChapterPublicCard {
  id: string;
  slug: string;
  name: string;
  description: string;
  cover_url: string | null;
  hub: { id: string; slug: string; name: string; emoji: string };
  owner_kind: "org" | "area";
  org: { slug: string; name: string } | null;
  campus: { slug: string; name: string } | null;
  area: { slug: string; name: string } | null;
  place_label: string;
  rso_name: string | null;
  pin_url: string | null;
  verified: boolean;
  member_count: number;
  upcoming_public_events: number;
}

const namedRef = z.object({ slug: z.string(), name: z.string() }).nullable().catch(null);
const publicCardSchema = z.object({
  id: z.string(),
  slug: z.string(),
  name: z.string(),
  description: z.string().catch(""),
  cover_url: z.string().nullable().catch(null),
  hub: z.object({ id: z.string(), slug: z.string(), name: z.string(), emoji: z.string() }),
  owner_kind: z.enum(["org", "area"]),
  org: namedRef,
  campus: namedRef,
  area: namedRef,
  place_label: z
    .string()
    .nullable()
    .transform((s) => s ?? ""),
  rso_name: z.string().nullable().catch(null),
  pin_url: z.string().nullable().catch(null),
  verified: z.boolean().catch(false),
  member_count: z.coerce.number().catch(0),
  upcoming_public_events: z.coerce.number().catch(0),
});

/** chapter_public_card's jsonb as a typed card; null for a missing chapter or a malformed answer. */
export function parsePublicCard(data: unknown): ChapterPublicCard | null {
  if (data === null || data === undefined) return null;
  const parsed = publicCardSchema.safeParse(data);
  return parsed.success ? parsed.data : null;
}

/* ------------------------------------------------------------------ */
/* Errors                                                               */
/* ------------------------------------------------------------------ */

function errorParts(err: unknown): { message: string; code: string } {
  if (typeof err === "object" && err !== null) {
    const o = err as Record<string, unknown>;
    return {
      message: typeof o.message === "string" ? o.message.trim() : "",
      code: typeof o.code === "string" ? o.code : "",
    };
  }
  return { message: String(err ?? ""), code: "" };
}

const MESSAGES: Record<string, string> = {
  not_authenticated: "Your session ended. Sign in again.",
  onboarding_required: "Finish setting up your profile first.",
  age_restricted: "This hub is for people older than you.",
  invalid_kind: "Pick a school organization or a neighborhood group.",
  agreement_required: "Agree to the captain guidelines to send the claim.",
  pin_url_invalid: "Links start with https://.",
  hub_not_found: "That hub doesn't exist anymore.",
  hub_inactive: "That hub is closed.",
  chapter_not_found: "That chapter doesn't exist anymore.",
  chapter_mismatch: "That chapter belongs to another hub.",
  org_required: "Verify a school email first, so we know which organization this is.",
  org_not_found: "That organization isn't on Activity Planet.",
  campus_not_found: "That campus isn't on Activity Planet.",
  membership_required: "This needs a verified school email for that organization.",
  area_required: "Pick a neighborhood.",
  area_not_found: "That neighborhood isn't on Activity Planet.",
  chapter_has_organizer: "This chapter already has an organizer.",
  name_required: "Give the chapter a name.",
  too_many_claims: "Up to three claims can be open at once. Wait for a review first.",
  claim_pending: "You already have an open claim for this chapter.",
  claim_not_found: "That claim isn't around anymore.",
  claim_not_pending: "That claim was already reviewed.",
  own_claim: "Another moderator has to review your own claim.",
  invalid_decision: "Approve or reject the claim.",
  claimant_inactive: "That account isn't active anymore.",
  invalid_role: "That role isn't valid.",
  forbidden: "You can't do that in this chapter.",
  organizer_requires_moderator: "Only a moderator can make someone an organizer.",
  not_a_member: "That person isn't in this chapter anymore.",
  last_organizer: "A chapter keeps at least one organizer.",
  member_inactive: "That account isn't active, so it can't take a role.",
  chapter_claims_proposed_name_length: "Chapter names are 2 to 100 characters.",
  chapter_claims_rso_name_length: "Group names are 2 to 120 characters.",
  chapter_claims_pin_url_format: "Links start with https://.",
  chapter_claims_officer_role_text_length: "Keep your role under 80 characters.",
  chapter_claims_reference_name_length: "Keep the name under 80 characters.",
  chapter_claims_reference_contact_length: "Keep the contact under 200 characters.",
  chapter_claims_motivation_length: "Keep this under 1,000 characters.",
};

/** A sentence for any error a chapter RPC or chapter_members write raises. */
export function chapterErrorMessage(err: unknown): string {
  const { message, code } = errorParts(err);
  const known = MESSAGES[message];
  if (known) return known;
  // chapter_members writes come back as PostgREST codes.
  if (code === "23505") return "You're already in this chapter.";
  if (code === "42501" || message.includes("row-level security"))
    return "This chapter is for verified members of its organization.";
  if (/Failed to fetch|NetworkError|Load failed/i.test(message))
    return "Check your connection and try again.";
  if (/^[a-z0-9_]+$/.test(message)) return `Couldn't do that (${message.replace(/_/g, " ")}).`;
  return "Something went wrong. Try again.";
}

/** The claim form field a server error belongs to, or null (show it at the top). */
export function fieldForClaimError(err: unknown): ClaimFormField | null {
  switch (errorParts(err).message) {
    case "agreement_required":
      return "agreed";
    case "pin_url_invalid":
    case "chapter_claims_pin_url_format":
      return "pinUrl";
    case "area_required":
    case "area_not_found":
      return "areaId";
    case "name_required":
    case "chapter_claims_proposed_name_length":
      return "proposedName";
    case "chapter_claims_rso_name_length":
      return "rsoName";
    case "chapter_claims_officer_role_text_length":
      return "officerRole";
    case "chapter_claims_reference_name_length":
      return "referenceName";
    case "chapter_claims_reference_contact_length":
      return "referenceContact";
    case "chapter_claims_motivation_length":
      return "motivation";
    default:
      return null;
  }
}
