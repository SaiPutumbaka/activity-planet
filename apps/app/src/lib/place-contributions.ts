import { queryOptions } from "@tanstack/react-query";
import type { Json } from "@ap/core/types";

import { placeRowId } from "./file-place-row";
import { placeKindInfo, type PlaceDetail } from "./map";
import { supabase } from "./supabase";

/**
 * Members add, correct and report places; moderators review them (HUB_MAP_DESIGN §5, §7 and §9,
 * slices 11 and 12; migration 34). Every rule is enforced by the database; this module only
 * shapes the calls, turns error codes into sentences and decodes the moderation queue.
 *
 *   await addPlace({ name, kind, lat, lng, isPublic: false })     // a private pin ("Only me")
 *   duplicateCandidates(err)                                     // [] or the places 60 m away
 *   await suggestPlaceEdit(id, placeChanges(detail, form), note)
 *   await reportPlace(id, "closed", note)
 *   useQuery(modPlaceQueueQuery())                               // moderators
 */

/* ------------------------------------------------------------------ */
/* Errors                                                               */
/* ------------------------------------------------------------------ */

function errorParts(err: unknown): { message: string; code: string; details: string } {
  if (typeof err === "object" && err !== null) {
    const o = err as Record<string, unknown>;
    return {
      message: typeof o.message === "string" ? o.message.trim() : "",
      code: typeof o.code === "string" ? o.code : "",
      details: typeof o.details === "string" ? o.details : "",
    };
  }
  return { message: String(err ?? ""), code: "", details: "" };
}

/** The server's error code (the exception message), or "". */
export function placeErrorCode(err: unknown): string {
  const m = errorParts(err).message;
  return /^[a-z0-9_]+$/.test(m) ? m : "";
}

const MESSAGES: Record<string, string> = {
  place_unavailable: "This place can't be changed right now. Try again in a moment.",
  not_authenticated: "Your session ended. Sign in again.",
  onboarding_required: "Finish setting up your profile first.",
  invalid_args: "Check the form and try again.",
  invalid_coordinates: "Move the map to the spot and try again.",
  kind_not_found: "Pick what kind of place this is.",
  name_length: "Give it a name of 2 to 120 characters.",
  address_length: "Keep the address under 200 characters.",
  locality_length: "Keep the area under 120 characters.",
  hours_length: "Keep the hours under 255 characters.",
  website_invalid: "Use a full link that starts with https://.",
  invalid_hubs: "Pick hubs from the list.",
  too_many_hubs: "Pick up to three hubs.",
  hub_not_allowed:
    "One of those hubs doesn't take member places (events-only hubs and hubs for faith, identity or health).",
  hub_required: "Pick at least one hub this place is for.",
  confirm_public_required: "Confirm this is a public place, not a home or private residence.",
  rate_limited: "That's the limit for today. Try again tomorrow.",
  near_your_home:
    "This spot is within 150 m of your saved home, so it can't be public. Keep it as a pin only you can see.",
  near_private_venue:
    "This spot is within 50 m of one of your private addresses, so it can't be public. Keep it as a pin only you can see.",
  duplicate_candidates: "There's already a place like this here.",
  place_not_found: "This place isn't available any more.",
  meeting_spot:
    "Meeting spots follow the venue of their plans, so they can't be edited. Report it if something is wrong.",
  no_changes: "Change something first.",
  invalid_changes: "Check the form and try again.",
  invalid_reason: "Pick a reason.",
  own_place: "This is your own place. Edit or delete it instead.",
  reviewed_place:
    "This place has been reviewed and is on the map for everyone. Suggest a correction or report it instead.",
  forbidden: "This is for moderators.",
  invalid_item: "That item is no longer in the queue.",
  invalid_action: "That action doesn't apply here.",
  item_not_pending: "Someone already decided this one.",
  own_item: "This one is yours. Another moderator decides it.",
  place_not_editable:
    "The place is hidden or removed. Reject the edit, or restore the place first.",
};

/** A sentence for any error the place RPCs raise. */
export function placeErrorMessage(err: unknown): string {
  const { message, code } = errorParts(err);
  const known = MESSAGES[message];
  if (known) return known;
  if (code === "42501" || /permission denied/i.test(message)) return "Sign in to do that.";
  if (/Failed to fetch|NetworkError|Load failed/i.test(message))
    return "Check your connection and try again.";
  if (/^[a-z0-9_]+$/.test(message)) return `Couldn't do that (${message.replace(/_/g, " ")}).`;
  return "Something went wrong. Try again.";
}

export interface DuplicateCandidate {
  id: string;
  name: string;
  kind: string;
  distanceM: number;
  mine: boolean;
}

/** The places a `duplicate_candidates` error lists (its detail is JSON), else []. */
export function duplicateCandidates(err: unknown): DuplicateCandidate[] {
  const { message, details } = errorParts(err);
  if (message !== "duplicate_candidates" || !details) return [];
  try {
    const raw: unknown = JSON.parse(details);
    if (!Array.isArray(raw)) return [];
    return raw.flatMap((c) => {
      if (!c || typeof c !== "object") return [];
      const o = c as Record<string, unknown>;
      if (typeof o.id !== "string" || !o.id) return [];
      return [
        {
          id: o.id,
          name: typeof o.name === "string" && o.name ? o.name : placeKindInfo(String(o.kind)).label,
          kind: typeof o.kind === "string" ? o.kind : "spot",
          distanceM: typeof o.distance_m === "number" ? Math.max(0, Math.round(o.distance_m)) : 0,
          mine: o.mine === true,
        },
      ];
    });
  } catch {
    return [];
  }
}

/* ------------------------------------------------------------------ */
/* Add a place                                                          */
/* ------------------------------------------------------------------ */

export interface AddPlaceInput {
  name: string;
  kind: string;
  lat: number;
  lng: number;
  /** Omitted: the server picks up to three of the viewer's joined hubs that show this kind. */
  hubIds?: string[];
  /** false = "Only me" (the default); true = "Everyone (reviewed first)". */
  isPublic: boolean;
  /** Required with isPublic: "This is a public place, not a home or private residence." */
  confirmPublic?: boolean;
  website?: string;
  hours?: string;
  /** The member looked at the duplicate candidates and says theirs is a different place. */
  allowDuplicate?: boolean;
}

export interface AddPlaceResult {
  id: string;
  status: "active" | "pending";
  isPublic: boolean;
  hubIds: string[];
}

/** The add_place(p_args) object: blank optional fields and an empty hub list are left out. */
export function addPlaceArgs(input: AddPlaceInput): Record<string, Json> {
  const args: Record<string, Json> = {
    name: input.name.trim(),
    kind: input.kind,
    lat: +input.lat.toFixed(6),
    lng: +input.lng.toFixed(6),
    is_public: input.isPublic,
  };
  if (input.hubIds?.length) args.hub_ids = [...new Set(input.hubIds)].slice(0, 3);
  if (input.isPublic) args.confirm_public = input.confirmPublic === true;
  const website = input.website?.trim();
  if (website) args.website = website;
  const hours = input.hours?.trim();
  if (hours) args.opening_hours = hours;
  if (input.allowDuplicate) args.allow_duplicate = true;
  return args;
}

function decodeAddResult(raw: unknown): AddPlaceResult {
  const o = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  return {
    id: typeof o.id === "string" ? o.id : "",
    status: o.status === "pending" ? "pending" : "active",
    isPublic: o.is_public === true,
    hubIds: Array.isArray(o.hub_ids)
      ? o.hub_ids.filter((h): h is string => typeof h === "string")
      : [],
  };
}

export async function addPlace(input: AddPlaceInput): Promise<AddPlaceResult> {
  const { data, error } = await supabase.rpc("add_place", { p_args: addPlaceArgs(input) });
  if (error) throw error;
  return decodeAddResult(data);
}

/* ------------------------------------------------------------------ */
/* Corrections                                                          */
/* ------------------------------------------------------------------ */

/** The editable facts of a place, as the correction form holds them. */
export interface PlaceFacts {
  name: string;
  kind: string;
  hours: string;
  website: string;
  address: string;
  closed: boolean;
}

export function factsOf(
  d: Pick<PlaceDetail, "name" | "kind" | "hours" | "website" | "address">,
): PlaceFacts {
  return {
    name: d.name,
    kind: d.kind,
    hours: d.hours ?? "",
    website: d.website ?? "",
    address: d.address ?? "",
    closed: false,
  };
}

/**
 * Only the fields the member changed, in suggest_place_edit's shape (an empty object when
 * nothing changed). Whitespace-only differences are not changes.
 */
export function placeChanges(before: PlaceFacts, after: PlaceFacts): Record<string, Json> {
  const out: Record<string, Json> = {};
  const t = (s: string) => s.trim();
  if (t(after.name) !== t(before.name)) out.name = t(after.name);
  if (after.kind !== before.kind) out.kind = after.kind;
  if (t(after.hours) !== t(before.hours)) out.opening_hours = t(after.hours);
  if (t(after.website) !== t(before.website)) out.website = t(after.website);
  if (t(after.address) !== t(before.address)) out.address_text = t(after.address);
  if (after.closed !== before.closed) out.closed = after.closed;
  return out;
}

export interface EditResult {
  id: string;
  status: "pending" | "applied" | "approved";
  applied: boolean;
}

export async function suggestPlaceEdit(
  placeId: string,
  changes: Record<string, Json>,
  note: string,
): Promise<EditResult> {
  const trimmed = note.trim();
  const { data, error } = await supabase.rpc("suggest_place_edit", {
    // A place read from a static file gets its database row first (D-042 slice 11).
    p_place: await placeRowId(placeId),
    p_changes: changes,
    ...(trimmed ? { p_note: trimmed } : {}),
  });
  if (error) throw error;
  const o = (data && typeof data === "object" ? data : {}) as Record<string, unknown>;
  return {
    id: typeof o.id === "string" ? o.id : "",
    status: o.status === "applied" || o.status === "approved" ? o.status : "pending",
    applied: o.applied === true,
  };
}

/* ------------------------------------------------------------------ */
/* Reports                                                              */
/* ------------------------------------------------------------------ */

export type ReportReason =
  | "closed"
  | "wrong_location"
  | "wrong_info"
  | "not_public"
  | "private_residence"
  | "unsafe"
  | "spam"
  | "other";

export const REPORT_REASONS: readonly { value: ReportReason; label: string }[] = [
  { value: "closed", label: "It's closed for good" },
  { value: "wrong_location", label: "The pin is in the wrong spot" },
  { value: "wrong_info", label: "The name or details are wrong" },
  { value: "not_public", label: "It isn't open to the public" },
  { value: "private_residence", label: "It's someone's home" },
  { value: "unsafe", label: "It's unsafe" },
  { value: "spam", label: "It's spam or fake" },
  { value: "other", label: "Something else" },
];

export function reportReasonLabel(reason: string): string {
  return REPORT_REASONS.find((r) => r.value === reason)?.label ?? "Something else";
}

export interface ReportResult {
  id: string;
  already: boolean;
  hidden: boolean;
}

export async function reportPlace(
  placeId: string,
  reason: ReportReason,
  note: string,
): Promise<ReportResult> {
  const trimmed = note.trim();
  const { data, error } = await supabase.rpc("report_place", {
    p_place: await placeRowId(placeId),
    p_reason: reason,
    ...(trimmed ? { p_note: trimmed } : {}),
  });
  if (error) throw error;
  const o = (data && typeof data === "object" ? data : {}) as Record<string, unknown>;
  return {
    id: typeof o.id === "string" ? o.id : "",
    already: o.already === true,
    hidden: o.hidden === true,
  };
}

/* ------------------------------------------------------------------ */
/* The creator's own pin                                                */
/* ------------------------------------------------------------------ */

export async function setMyPlaceVisibility(
  placeId: string,
  isPublic: boolean,
  confirm: boolean,
): Promise<{ status: string; isPublic: boolean }> {
  const { data, error } = await supabase.rpc("set_my_place_visibility", {
    p_place: placeId,
    p_public: isPublic,
    p_confirm: confirm,
  });
  if (error) throw error;
  const o = (data && typeof data === "object" ? data : {}) as Record<string, unknown>;
  return { status: typeof o.status === "string" ? o.status : "", isPublic: o.is_public === true };
}

export async function deleteMyPlace(placeId: string): Promise<void> {
  const { error } = await supabase.rpc("delete_my_place", { p_place: placeId });
  if (error) throw error;
}

/** What the creator can still do with their own pin (a reviewed public place is shared). */
export function ownPinActions(d: Pick<PlaceDetail, "mine" | "source" | "private" | "pending">): {
  edit: boolean;
  makePublic: boolean;
  makePrivate: boolean;
  remove: boolean;
} {
  const own = d.mine && d.source === "user" && (d.private || d.pending);
  return {
    edit: own,
    makePublic: own && d.private,
    makePrivate: own && d.pending && !d.private,
    remove: own,
  };
}

/* ------------------------------------------------------------------ */
/* Moderation queue (slice 12)                                          */
/* ------------------------------------------------------------------ */

export type ModItemKind = "place" | "edit" | "reports";

export interface ModPlace {
  id: string;
  name: string;
  kind: string;
  kindLabel: string;
  lat: number;
  lng: number;
  address: string | null;
  locality: string | null;
  hours: string | null;
  website: string | null;
  source: string;
  status: string;
  isPublic: boolean;
  lockedFields: string[];
  memberAdded: boolean;
  osmUrl: string | null;
  creatorAccountDays: number | null;
  hubs: { id: string; name: string; emoji: string; via: string }[];
  nearby: { id: string; name: string; kind: string; distanceM: number }[];
}

export interface ModItem {
  kind: ModItemKind;
  id: string;
  createdAt: Date | null;
  place: ModPlace;
  own: boolean;
  /** edit */
  changes?: Record<string, unknown>;
  current?: Record<string, unknown>;
  note?: string | null;
  moveM?: number | null;
  /** reports */
  open?: number;
  reporters?: number;
  reasons?: Record<string, number>;
  reports?: { id: string; reason: string; note: string | null; createdAt: Date | null }[];
}

export interface ModQueue {
  items: ModItem[];
  counts: { places: number; edits: number; reports: number };
}

function str(v: unknown): string | null {
  return typeof v === "string" && v ? v : null;
}
function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}
function date(v: unknown): Date | null {
  const s = str(v);
  if (!s) return null;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}
function obj(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}

function decodeModPlace(raw: unknown): ModPlace | null {
  const o = obj(raw);
  const id = str(o?.id);
  if (!o || !id) return null;
  const kind = str(o.kind) ?? "spot";
  const osm = str(o.osm_url);
  return {
    id,
    name: str(o.name) ?? placeKindInfo(kind).label,
    kind,
    kindLabel: str(o.kind_label) ?? placeKindInfo(kind).label,
    lat: num(o.lat) ?? 0,
    lng: num(o.lng) ?? 0,
    address: str(o.address_text),
    locality: str(o.locality),
    hours: str(o.opening_hours),
    website: str(o.website),
    source: str(o.source) ?? "osm",
    status: str(o.status) ?? "active",
    isPublic: o.is_public === true,
    lockedFields: Array.isArray(o.locked_fields)
      ? o.locked_fields.filter((f): f is string => typeof f === "string")
      : [],
    memberAdded: o.member_added === true,
    osmUrl:
      osm && /^https:\/\/www\.openstreetmap\.org\/(node|way|relation)\/\d+$/.test(osm) ? osm : null,
    creatorAccountDays: num(o.creator_account_days),
    hubs: Array.isArray(o.hubs)
      ? o.hubs.flatMap((h) => {
          const x = obj(h);
          const hid = str(x?.id);
          return x && hid
            ? [
                {
                  id: hid,
                  name: str(x.name) ?? "",
                  emoji: str(x.emoji) ?? "",
                  via: str(x.via) ?? "",
                },
              ]
            : [];
        })
      : [],
    nearby: Array.isArray(o.nearby)
      ? o.nearby.flatMap((n) => {
          const x = obj(n);
          const nid = str(x?.id);
          return x && nid
            ? [
                {
                  id: nid,
                  name: str(x.name) ?? "",
                  kind: str(x.kind) ?? "spot",
                  distanceM: num(x.distance_m) ?? 0,
                },
              ]
            : [];
        })
      : [],
  };
}

/** The mod_place_queue jsonb to a ModQueue; malformed items are dropped. */
export function decodeModQueue(raw: unknown): ModQueue {
  const o = obj(raw) ?? {};
  const counts = obj(o.counts) ?? {};
  const items = Array.isArray(o.items)
    ? o.items.flatMap((it): ModItem[] => {
        const x = obj(it);
        if (!x) return [];
        const kind = x.kind;
        const id = str(x.id);
        const place = decodeModPlace(x.place);
        if ((kind !== "place" && kind !== "edit" && kind !== "reports") || !id || !place) return [];
        const item: ModItem = {
          kind,
          id,
          createdAt: date(x.created_at),
          place,
          own: x.own === true,
        };
        if (kind === "edit") {
          item.changes = obj(x.changes) ?? {};
          item.current = obj(x.current) ?? {};
          item.note = str(x.note);
          item.moveM = num(x.move_m);
        }
        if (kind === "reports") {
          item.open = num(x.open) ?? 0;
          item.reporters = num(x.reporters) ?? 0;
          const reasons = obj(x.reasons) ?? {};
          item.reasons = Object.fromEntries(
            Object.entries(reasons).flatMap(([k, v]) => (typeof v === "number" ? [[k, v]] : [])),
          );
          item.reports = Array.isArray(x.reports)
            ? x.reports.flatMap((r) => {
                const y = obj(r);
                const rid = str(y?.id);
                return y && rid
                  ? [
                      {
                        id: rid,
                        reason: str(y.reason) ?? "other",
                        note: str(y.note),
                        createdAt: date(y.created_at),
                      },
                    ]
                  : [];
              })
            : [];
        }
        return [item];
      })
    : [];
  return {
    items,
    counts: {
      places: num(counts.places) ?? 0,
      edits: num(counts.edits) ?? 0,
      reports: num(counts.reports) ?? 0,
    },
  };
}

export const modPlaceKeys = { queue: ["places", "mod-queue"] as const };

export const modPlaceQueueQuery = () =>
  queryOptions({
    queryKey: modPlaceKeys.queue,
    queryFn: async (): Promise<ModQueue> => {
      const { data, error } = await supabase.rpc("mod_place_queue", { p_limit: 100 });
      if (error) throw error;
      return decodeModQueue(data);
    },
    staleTime: 15_000,
  });

export type ModAction = "approve" | "reject" | "remove" | "dismiss" | "hide" | "close";

/** The actions each kind of item takes, in button order (the last is the primary one). */
export const MOD_ACTIONS: Record<ModItemKind, readonly { action: ModAction; label: string }[]> = {
  place: [
    { action: "remove", label: "Remove" },
    { action: "reject", label: "Keep private" },
    { action: "approve", label: "Approve" },
  ],
  edit: [
    { action: "reject", label: "Reject" },
    { action: "approve", label: "Apply" },
  ],
  reports: [
    { action: "remove", label: "Remove" },
    { action: "close", label: "Mark closed" },
    { action: "hide", label: "Hide" },
    { action: "dismiss", label: "Dismiss" },
  ],
};

export async function modResolvePlace(
  kind: ModItemKind,
  id: string,
  action: ModAction,
  note: string,
): Promise<{ placeStatus: string }> {
  const trimmed = note.trim();
  const { data, error } = await supabase.rpc("mod_resolve_place", {
    p_kind: kind,
    p_id: id,
    p_action: action,
    ...(trimmed ? { p_note: trimmed } : {}),
  });
  if (error) throw error;
  const o = obj(data) ?? {};
  return { placeStatus: str(o.place_status) ?? "" };
}

/** A readable line for one changed field of an edit: "Name: Old → New". */
export function describeChange(field: string, before: unknown, after: unknown): string {
  const label: Record<string, string> = {
    name: "Name",
    kind: "Kind",
    location: "Location",
    address_text: "Address",
    locality: "Area",
    opening_hours: "Hours",
    website: "Website",
    closed: "Closed",
    hubs_add: "Add hubs",
  };
  const show = (v: unknown): string => {
    if (v === null || v === undefined || v === "") return "(empty)";
    if (typeof v === "boolean") return v ? "yes" : "no";
    if (field === "kind" && typeof v === "string") return placeKindInfo(v).label;
    if (field === "location" && typeof v === "object") {
      const o = v as Record<string, unknown>;
      return `${String(o.lat)}, ${String(o.lng)}`;
    }
    if (Array.isArray(v)) return `${v.length} hub${v.length === 1 ? "" : "s"}`;
    return typeof v === "string" || typeof v === "number" ? String(v) : JSON.stringify(v);
  };
  if (field === "hubs_add") return `${label[field]}: ${show(after)}`;
  return `${label[field] ?? field}: ${show(before)} → ${show(after)}`;
}
