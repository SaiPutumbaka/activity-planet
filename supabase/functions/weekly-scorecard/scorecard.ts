// weekly-scorecard logic (migration 67, D-045; RECS_DESIGN.md section 10). Pure: the RPCs and the
// email sender are injected. Counts only: the email holds numbers, a link to the admin panel and
// no names or rows. Without RESEND_API_KEY or SCORECARD_TO the run is recorded as skipped_no_key
// and nothing else is called. A week already sent is never sent again.

export type Rpc = (name: string, args: Record<string, unknown>) => Promise<unknown>;

export interface ScorecardEmail {
  id: string;
  to: string;
  subject: string;
  text: string;
  html: string;
  headers: Record<string, string>;
}

export interface ScorecardDeps {
  rpc: Rpc;
  resendKey: string;
  to: string;
  send: (m: ScorecardEmail) => Promise<"sent" | "failed" | "retry">;
  adminUrl: string;
  posthogUrl?: string;
}

export type Counts = { [k: string]: number | string | Counts | null };

export interface Row {
  path: string[];
  value: number;
  delta: number | null;
}

/** Every numeric leaf with its change against last week (null when last week had no value). */
export function flatten(curr: Counts, prev: Counts | null, path: string[] = []): Row[] {
  const out: Row[] = [];
  for (const [k, v] of Object.entries(curr)) {
    if (k === "week_start") continue;
    const p =
      prev && typeof prev === "object" ? (prev[k] as Counts | number | undefined) : undefined;
    if (typeof v === "number") {
      const before = typeof p === "number" ? p : null;
      out.push({ path: [...path, k], value: v, delta: before === null ? null : round(v - before) });
    } else if (v && typeof v === "object") {
      out.push(...flatten(v, p && typeof p === "object" ? (p as Counts) : null, [...path, k]));
    }
  }
  return out;
}

function round(n: number): number {
  return Math.round(n * 1000) / 1000;
}

function label(path: string[]): string {
  return path.map((p) => p.replaceAll("_", " ")).join(" / ");
}

function deltaText(d: number | null): string {
  if (d === null) return "";
  if (d === 0) return "(no change)";
  return d > 0 ? `(+${d})` : `(${d})`;
}

function esc(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function render(
  week: string,
  curr: Counts,
  prev: Counts | null,
  links: { adminUrl: string; posthogUrl?: string },
): { subject: string; text: string; html: string } {
  const rows = flatten(curr, prev);
  const subject = `Activity Planet weekly scorecard, week of ${week}`;
  const lines = rows.map((r) => `${label(r.path)}: ${r.value} ${deltaText(r.delta)}`.trimEnd());
  const extra = [`Admin panel: ${links.adminUrl}`];
  if (links.posthogUrl) extra.push(`Imported-shelf clicks: ${links.posthogUrl}`);
  const text = [subject, "", ...lines, "", ...extra, ""].join("\n");
  const html =
    `<h1>${esc(subject)}</h1><table>` +
    rows
      .map(
        (r) =>
          `<tr><td>${esc(label(r.path))}</td><td align="right">${r.value}</td><td>${esc(deltaText(r.delta))}</td></tr>`,
      )
      .join("") +
    `</table><p><a href="${esc(links.adminUrl)}">Admin panel</a>` +
    (links.posthogUrl ? ` · <a href="${esc(links.posthogUrl)}">Imported-shelf clicks</a>` : "") +
    `</p>`;
  return { subject, text, html };
}

export function validWeek(v: unknown): string | null {
  return typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null;
}

export type RunResult =
  | { status: "skipped_no_key"; week_start: string | null }
  | { status: "already_sent"; week_start: string }
  | { status: "sent" | "failed"; week_start: string; rows: number };

export async function runScorecard(
  deps: ScorecardDeps,
  weekStart: string | null,
): Promise<RunResult> {
  if (!deps.resendKey || !deps.to) {
    const r = (await deps.rpc("scorecard_record", {
      p_week_start: weekStart,
      p_counts: {},
      p_status: "skipped_no_key",
      p_error: null,
    })) as { week_start?: string } | null;
    return { status: "skipped_no_key", week_start: r?.week_start ?? weekStart };
  }
  const state = (await deps.rpc("scorecard_run_state", { p_week_start: weekStart })) as {
    week_start: string;
    status: string | null;
    previous_counts: Counts | null;
  };
  const week = state.week_start;
  if (state.status === "sent") return { status: "already_sent", week_start: week };
  const counts = (await deps.rpc("scorecard_week", { p_week_start: week })) as Counts;
  const { subject, text, html } = render(week, counts, state.previous_counts, deps);
  // Migration 77: the scorecard counts against the account-wide email budget (which keeps a
  // reserve for sign-up and password email); past it nothing is sent and the run is failed.
  const allowed = await deps.rpc("email_budget_take", { p_source: "scorecard", p_n: 1 });
  if (allowed !== true) {
    await deps.rpc("scorecard_record", {
      p_week_start: week,
      p_counts: counts,
      p_status: "failed",
      p_error: "email_budget",
    });
    return { status: "failed", week_start: week, rows: flatten(counts, null).length };
  }
  const result = await deps.send({
    id: `scorecard-${week}`,
    to: deps.to,
    subject,
    text,
    html,
    headers: {},
  });
  const status = result === "sent" ? "sent" : "failed";
  await deps.rpc("scorecard_record", {
    p_week_start: week,
    p_counts: counts,
    p_status: status,
    p_error: status === "sent" ? null : `resend_${result}`,
  });
  return { status, week_start: week, rows: flatten(counts, null).length };
}
