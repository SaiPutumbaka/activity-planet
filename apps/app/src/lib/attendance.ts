import { queryOptions } from "@tanstack/react-query";
import type { Database } from "@ap/core/types";

import { supabase } from "./supabase";

/**
 * Attendance (PLAN.md 4.9, migration 20): the morning-after "Did you go? Who did you meet?"
 * prompt and the chapter dashboard. Every write is an RPC; the client may read its own
 * event_attendance_reports and event_meets rows (RLS: owner select). Who someone picked stays
 * private to them.
 *
 *   useQuery(pendingAttendancePromptsQuery(userId))   // Home card: up to 5 unanswered plans
 *   useQuery(myAttendanceQuery(eventId, userId))      // the viewer's answer and picks, or null
 *   await submitAttendance(eventId, true, [metId])    // idempotent; replaces earlier picks
 *   await dismissAttendancePrompt(eventId)            // hide the Home card for that plan
 *   useQuery(chapterDashboardQuery(chapterId, 12))    // counts only, for captains
 *   attendanceErrorMessage(err)                       // "This plan hasn't ended yet."
 */

type Functions = Database["public"]["Functions"];
type PromptRow = Functions["pending_attendance_prompts"]["Returns"][number];

/** submit_attendance accepts up to this many people met per plan. */
export const MAX_MET = 30;
/** submit_attendance is open from the plan's end until this long after it. */
export const ATTENDANCE_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;
/** chapter_dashboard accepts 1 to 52 weeks. */
export const DASHBOARD_WEEK_OPTIONS = [4, 12, 26] as const;
export type DashboardWeeks = (typeof DASHBOARD_WEEK_OPTIONS)[number];

export const attendanceKeys = {
  all: ["attendance"] as const,
  prompts: (userId: string) => ["attendance", "prompts", userId] as const,
  mine: (eventId: string, userId: string) => ["attendance", "mine", eventId, userId] as const,
  dashboard: (chapterId: string, weeks: number) =>
    ["attendance", "dashboard", chapterId, weeks] as const,
};

/* ------------------------------------------------------------------ */
/* Parsing                                                              */
/* ------------------------------------------------------------------ */

export interface PromptAttendee {
  id: string;
  first_name: string;
  avatar_url: string | null;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim() !== "" ? v : null;
}

function int(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? Math.max(0, Math.floor(v)) : 0;
}

/** The attendees jsonb of pending_attendance_prompts: [{id, first_name, avatar_url}]. Bad entries dropped. */
export function parseAttendees(raw: unknown): PromptAttendee[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const out: PromptAttendee[] = [];
  for (const r of raw) {
    if (!isRecord(r)) continue;
    const id = str(r.id);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push({ id, first_name: str(r.first_name) ?? "Member", avatar_url: str(r.avatar_url) });
  }
  return out;
}

export interface AttendancePrompt extends Omit<PromptRow, "attendees"> {
  attendees: PromptAttendee[];
}

export interface SubmitResult {
  eventId: string;
  attended: boolean;
  metCount: number;
  checkedIn: boolean;
}

/** submit_attendance's {event_id, attended, met_count, checked_in}. */
export function parseSubmitResult(raw: unknown, fallback: { eventId: string; attended: boolean }) {
  const r = isRecord(raw) ? raw : {};
  return {
    eventId: str(r.event_id) ?? fallback.eventId,
    attended: typeof r.attended === "boolean" ? r.attended : fallback.attended,
    metCount: int(r.met_count),
    checkedIn: r.checked_in === true,
  } satisfies SubmitResult;
}

export interface DashboardWeek {
  weekStart: string;
  eventsHeld: number;
  going: number;
  checkedIn: number;
  selfReported: number;
  distinctAttendees: number;
  returningAttendees: number;
}

export interface DashboardTotals {
  eventsHeld: number;
  going: number;
  checkedIn: number;
  selfReported: number;
  distinctAttendees: number;
  returningAttendees: number;
}

export interface ChapterDashboard {
  chapterId: string;
  weeks: number;
  timezone: string;
  from: string | null;
  to: string | null;
  membersCount: number;
  totals: DashboardTotals;
  byWeek: DashboardWeek[];
}

function totalsOf(r: Record<string, unknown>): DashboardTotals {
  return {
    eventsHeld: int(r.events_held),
    going: int(r.going),
    checkedIn: int(r.checked_in),
    selfReported: int(r.self_reported),
    distinctAttendees: int(r.distinct_attendees),
    returningAttendees: int(r.returning_attendees),
  };
}

/** chapter_dashboard's jsonb. Weeks without a valid week_start are dropped; order kept (oldest first). */
export function parseDashboard(raw: unknown): ChapterDashboard | null {
  if (!isRecord(raw)) return null;
  const chapterId = str(raw.chapter_id);
  if (!chapterId) return null;
  const byWeek: DashboardWeek[] = [];
  if (Array.isArray(raw.by_week)) {
    for (const w of raw.by_week) {
      if (!isRecord(w)) continue;
      const weekStart = str(w.week_start);
      if (!weekStart || !/^\d{4}-\d{2}-\d{2}/.test(weekStart)) continue;
      byWeek.push({ weekStart: weekStart.slice(0, 10), ...totalsOf(w) });
    }
  }
  return {
    chapterId,
    weeks: int(raw.weeks) || byWeek.length,
    timezone: str(raw.timezone) ?? "America/New_York",
    from: str(raw.from),
    to: str(raw.to),
    membersCount: int(raw.members_count),
    totals: totalsOf(isRecord(raw.totals) ? raw.totals : {}),
    byWeek,
  };
}

/* ------------------------------------------------------------------ */
/* Queries and RPCs                                                     */
/* ------------------------------------------------------------------ */

/** Plans that ended in the last 7 days where the viewer was going and hasn't answered. */
export const pendingAttendancePromptsQuery = (userId: string) =>
  queryOptions({
    queryKey: attendanceKeys.prompts(userId),
    queryFn: async (): Promise<AttendancePrompt[]> => {
      const { data, error } = await supabase.rpc("pending_attendance_prompts");
      if (error) throw error;
      return (data ?? []).map((r) => ({ ...r, attendees: parseAttendees(r.attendees) }));
    },
    staleTime: 60_000,
  });

export interface MyAttendance {
  attended: boolean | null;
  answeredAt: string | null;
  dismissedAt: string | null;
  /** Who the viewer picked last time (private to them). */
  met: string[];
}

/** The viewer's own answer for one plan, or null when they haven't answered or dismissed. */
export const myAttendanceQuery = (eventId: string, userId: string) =>
  queryOptions({
    queryKey: attendanceKeys.mine(eventId, userId),
    queryFn: async (): Promise<MyAttendance | null> => {
      const [report, meets] = await Promise.all([
        supabase
          .from("event_attendance_reports")
          .select("attended,answered_at,dismissed_at")
          .eq("event_id", eventId)
          .eq("user_id", userId)
          .maybeSingle(),
        supabase
          .from("event_meets")
          .select("met_user_id")
          .eq("event_id", eventId)
          .eq("user_id", userId),
      ]);
      if (report.error) throw report.error;
      if (meets.error) throw meets.error;
      if (!report.data) return null;
      return {
        attended: report.data.attended,
        answeredAt: report.data.answered_at,
        dismissedAt: report.data.dismissed_at,
        met: meets.data.map((m) => m.met_user_id),
      };
    },
    staleTime: 30_000,
  });

export async function submitAttendance(
  eventId: string,
  attended: boolean,
  met: string[] = [],
): Promise<SubmitResult> {
  const { data, error } = await supabase.rpc("submit_attendance", {
    p_event_id: eventId,
    p_attended: attended,
    p_met: attended ? cleanMet(met) : [],
  });
  if (error) throw error;
  return parseSubmitResult(data, { eventId, attended });
}

export async function dismissAttendancePrompt(eventId: string): Promise<void> {
  const { error } = await supabase.rpc("dismiss_attendance_prompt", { p_event_id: eventId });
  if (error) throw error;
}

/** Counts for a chapter's captains, organizers and moderators. Raises forbidden for anyone else. */
export const chapterDashboardQuery = (chapterId: string, weeks: number) =>
  queryOptions({
    queryKey: attendanceKeys.dashboard(chapterId, weeks),
    queryFn: async (): Promise<ChapterDashboard | null> => {
      const { data, error } = await supabase.rpc("chapter_dashboard", {
        p_chapter: chapterId,
        p_weeks: weeks,
      });
      if (error) throw error;
      return parseDashboard(data);
    },
    staleTime: 5 * 60_000,
    // forbidden is an answer, not a blip.
    retry: (failures, err) => !isForbidden(err) && failures < 1,
  });

/* ------------------------------------------------------------------ */
/* Pure helpers                                                         */
/* ------------------------------------------------------------------ */

/** Distinct, non-empty ids, at most MAX_MET (what submit_attendance accepts). */
export function cleanMet(ids: readonly string[]): string[] {
  return [...new Set(ids.filter((id) => typeof id === "string" && id.trim() !== ""))].slice(
    0,
    MAX_MET,
  );
}

/** Adds or removes one person; adding past MAX_MET leaves the selection unchanged. */
export function toggleMet(selected: readonly string[], id: string): string[] {
  if (selected.includes(id)) return selected.filter((x) => x !== id);
  if (selected.length >= MAX_MET) return [...selected];
  return [...selected, id];
}

/** submit_attendance's window: from the plan's end to 7 days after, and not cancelled. */
export function attendanceWindowOpen(
  event: { status: string; ends_at: string },
  now: Date = new Date(),
): boolean {
  if (event.status === "cancelled") return false;
  const end = new Date(event.ends_at).getTime();
  if (!Number.isFinite(end)) return false;
  const t = now.getTime();
  return t >= end && t <= end + ATTENDANCE_WINDOW_MS;
}

/**
 * Whether the event page offers "Did you go?": a going RSVP (not the host, who obviously went),
 * not an imported listing, inside the window.
 */
export function canAnswerAttendance(opts: {
  event: { status: string; ends_at: string; kind: string };
  status: string | null | undefined;
  isHost: boolean;
  now?: Date;
}): boolean {
  return (
    opts.status === "going" &&
    !opts.isHost &&
    opts.event.kind !== "imported" &&
    attendanceWindowOpen(opts.event, opts.now)
  );
}

/** The friendly line after an answer. Everyone-first (D-035): no audience assumed. */
export function attendanceConfirmation(result: Pick<SubmitResult, "attended" | "metCount">): {
  title: string;
  body: string;
} {
  if (!result.attended) {
    return {
      title: "Thanks for telling us",
      body: "Hope the next one works out. There's always something on this week.",
    };
  }
  if (result.metCount <= 0) {
    return { title: "Glad you made it", body: "Thanks for letting us know you went." };
  }
  const people = result.metCount === 1 ? "1 person" : `${result.metCount} people`;
  return {
    title: "Glad you made it",
    body: `You picked ${people} you met. Only you can see who you picked.`,
  };
}

/** "Ana, Ben and 3 others were going", for the Home card. */
export function attendeesLine(attendees: readonly PromptAttendee[]): string | null {
  const names = attendees.map((a) => a.first_name);
  if (names.length === 0) return null;
  if (names.length === 1) return `${names[0]} was going`;
  if (names.length === 2) return `${names[0]} and ${names[1]} were going`;
  const rest = names.length - 2;
  return `${names[0]}, ${names[1]} and ${rest} ${rest === 1 ? "other" : "others"} were going`;
}

/** Share of a week's attendees who had been to an earlier chapter plan; null with no attendees. */
export function returningRate(w: { distinctAttendees: number; returningAttendees: number }) {
  if (w.distinctAttendees <= 0) return null;
  return Math.min(1, Math.max(0, w.returningAttendees / w.distinctAttendees));
}

/** 0.4 → "40%"; null → "–". */
export function formatPercent(rate: number | null): string {
  return rate === null ? "–" : `${Math.round(rate * 100)}%`;
}

/** The bar scale's top: the largest weekly attendee count, never below 1. */
export function chartMax(weeks: readonly { distinctAttendees: number }[]): number {
  return Math.max(1, ...weeks.map((w) => w.distinctAttendees));
}

/** A bar's height as a percentage of the plot, 0 to 100. */
export function barPercent(value: number, max: number): number {
  if (!(max > 0) || !(value > 0)) return 0;
  return Math.min(100, (value / max) * 100);
}

/** "2026-11-02" → "Nov 2" (a calendar date, so no timezone shift). */
export function formatWeekLabel(weekStart: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(weekStart);
  if (!m) return weekStart;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", timeZone: "UTC" })
    .format(d)
    .replace(",", "");
}

/* ------------------------------------------------------------------ */
/* Errors                                                               */
/* ------------------------------------------------------------------ */

const MESSAGES: Record<string, string> = {
  not_authenticated: "Your session ended. Sign in again.",
  attended_required: "Pick yes or no.",
  event_not_found: "This plan isn't available anymore.",
  not_going: "Only people who were going can answer for this plan.",
  event_cancelled: "This plan was cancelled.",
  event_not_over: "This plan hasn't ended yet. Ask again once it's over.",
  attendance_window_closed: "It's been more than a week since this plan, so it's closed now.",
  too_many_met: `You can pick up to ${MAX_MET} people.`,
  met_requires_attended: "You can only pick people you met if you went.",
  met_self: "You can't pick yourself.",
  met_not_going: "Someone you picked wasn't going to this plan. Refresh and try again.",
  forbidden: "Only the chapter's captains and organizers can see this.",
  chapter_not_found: "That chapter isn't here anymore.",
  weeks_range: "Pick between 1 and 52 weeks.",
};

function errorCode(err: unknown): string {
  return typeof err === "object" && err && "message" in err && typeof err.message === "string"
    ? err.message.trim()
    : "";
}

export function attendanceErrorMessage(err: unknown): string {
  const code = errorCode(err);
  const known = MESSAGES[code];
  if (known) return known;
  if (/Failed to fetch|NetworkError|Load failed/i.test(code))
    return "Couldn't reach the server. Check your connection and try again.";
  return "Something went wrong. Try again.";
}

export function isForbidden(err: unknown): boolean {
  return errorCode(err) === "forbidden";
}

/** Show every nth week label under the chart so at most `maxLabels` fit (always the first). */
export function labelStep(count: number, maxLabels = 6): number {
  if (count <= maxLabels) return 1;
  return Math.ceil(count / maxLabels);
}
