import { queryOptions } from "@tanstack/react-query";
import { checkCalendarUrl, type CalendarUrlCheck } from "@ap/core/validation";

import { supabase } from "./supabase";

/**
 * "Suggest a calendar" (D-042 slice 7, AUTO_COVERAGE_DESIGN 6.1 item 3; migration 46). A member
 * sends a public calendar URL; the database checks it again (D-040 rules and the denylist), allows
 * five a day, and keeps the URL without who sent it. A moderator approves it before the collector
 * ever reads it, and it is listed only after it gives events on two separate days.
 *
 *   checkSuggestion(url)               // the same URL rules as the server, minus the denylist
 *   await suggestCalendar(url)         // { status: "received" | "already_known", host }
 *   useQuery(pendingSuggestionsQuery()) // moderators
 *   await reviewSuggestion(id, true)
 */

export type SuggestStatus = "received" | "already_known";

export interface SuggestResult {
  status: SuggestStatus;
  host: string;
}

const MESSAGES: Record<string, string> = {
  not_authenticated: "Your session ended. Sign in again.",
  onboarding_required: "Finish setting up your profile first.",
  url_invalid: "That doesn't look like a web address. Paste the full link to the calendar page.",
  url_too_long: "That link is too long. Try the calendar's main page instead.",
  url_not_https: "Use a web link (https://), or a calendar feed link (webcal://).",
  url_has_credentials: "Remove the user name and password from the link.",
  url_port: "Use the calendar's normal web address, without a port number.",
  url_private_host: "That address isn't on the public web. Suggest a calendar anyone can open.",
  url_denylisted:
    "That site doesn't allow its pages to be collected automatically, so we can't list its events. If the organisation also has a calendar on its own website, suggest that one.",
  rate_limited: "Thanks, that's five for today. You can suggest more tomorrow.",
  queue_full: "Our review queue is full right now. Try again in a few days.",
  forbidden: "This is for moderators.",
  invalid_item: "That suggestion is no longer in the queue.",
  invalid_action: "That action doesn't apply here.",
  item_not_pending: "Someone already decided this one.",
};

function messageOf(err: unknown): { message: string; code: string } {
  if (typeof err === "object" && err !== null) {
    const o = err as Record<string, unknown>;
    return {
      message: typeof o.message === "string" ? o.message.trim() : "",
      code: typeof o.code === "string" ? o.code : "",
    };
  }
  return { message: String(err ?? ""), code: "" };
}

/** A sentence for any error suggest_calendar or mod_review_source_candidate raises. */
export function suggestionErrorMessage(err: unknown): string {
  const { message, code } = messageOf(err);
  const known = MESSAGES[message];
  if (known) return known;
  if (code === "42501" || /permission denied/i.test(message)) return "Sign in to do that.";
  if (/Failed to fetch|NetworkError|Load failed/i.test(message))
    return "Check your connection and try again.";
  return "Something went wrong. Try again.";
}

/** The form's own check: null when the server should see it, else the sentence to show. */
export function checkSuggestion(input: string): { check: CalendarUrlCheck; error: string | null } {
  const check = checkCalendarUrl(input);
  return { check, error: check.ok ? null : (MESSAGES[check.error] ?? MESSAGES.url_invalid!) };
}

export function decodeSuggestResult(raw: unknown): SuggestResult {
  const o = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  return {
    status: o.status === "already_known" ? "already_known" : "received",
    host: typeof o.host === "string" ? o.host : "",
  };
}

export async function suggestCalendar(url: string): Promise<SuggestResult> {
  const { data, error } = await supabase.rpc("suggest_calendar", { p_url: url.trim() });
  if (error) throw error;
  return decodeSuggestResult(data);
}

/* ------------------------------------------------------------------ */
/* Moderation                                                           */
/* ------------------------------------------------------------------ */

export interface PendingSuggestion {
  id: string;
  url: string;
  host: string;
  suggestCount: number;
  createdAt: string;
  regionLabel: string | null;
}

export const suggestionKeys = {
  pending: ["calendar-suggestions", "pending"] as const,
};

export function decodePending(rows: unknown): PendingSuggestion[] {
  if (!Array.isArray(rows)) return [];
  return rows.flatMap((r) => {
    if (!r || typeof r !== "object") return [];
    const o = r as Record<string, unknown>;
    if (typeof o.id !== "string" || typeof o.url !== "string") return [];
    const region = o.collector_regions as { label?: unknown } | null | undefined;
    return [
      {
        id: o.id,
        url: o.url,
        host: typeof o.host === "string" ? o.host : "",
        suggestCount: typeof o.suggest_count === "number" ? o.suggest_count : 1,
        createdAt: typeof o.created_at === "string" ? o.created_at : "",
        regionLabel: region && typeof region.label === "string" ? region.label : null,
      },
    ];
  });
}

/** Pending member suggestions, oldest first (rows readable by moderators only, RLS). */
export const pendingSuggestionsQuery = () =>
  queryOptions({
    queryKey: suggestionKeys.pending,
    queryFn: async (): Promise<PendingSuggestion[]> => {
      const { data, error } = await supabase
        .from("source_candidates")
        .select("id, url, host, suggest_count, created_at, collector_regions(label)")
        .eq("review_status", "pending")
        .order("created_at", { ascending: true })
        .limit(100);
      if (error) throw error;
      return decodePending(data);
    },
  });

export async function reviewSuggestion(id: string, approve: boolean, reason?: string) {
  const { error } = await supabase.rpc("mod_review_source_candidate", {
    p_id: id,
    p_approve: approve,
    ...(reason?.trim() ? { p_reason: reason.trim() } : {}),
  });
  if (error) throw error;
}
