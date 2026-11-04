// RRULE expansion (RFC 5545 3.3.10 and 3.8.5.3), in the event's own wall-clock time so a
// weekly 7 pm meeting stays at 7 pm across a DST change. Covers what public calendars use:
// FREQ DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, COUNT, UNTIL, BYDAY (with ordinals for
// monthly and yearly), BYMONTHDAY (negative too), BYMONTH, BYSETPOS and WKST. BYHOUR,
// BYMINUTE, BYWEEKNO and BYYEARDAY are not expanded; such rules yield DTSTART only.

import { addDays, type Civil, compareCivil, daysInMonth, weekday } from "../util/time.ts";

const DAYS: Record<string, number> = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

export interface RRule {
  freq: "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY";
  interval: number;
  count: number | null;
  /** Raw UNTIL value ("20261231", "20261231T235959Z" or a local date-time). */
  until: string | null;
  byDay: { n: number | null; wd: number }[];
  byMonthDay: number[];
  byMonth: number[];
  bySetPos: number[];
  wkst: number;
  unsupported: boolean;
}

export function parseRRule(value: string): RRule | null {
  const parts = new Map<string, string>();
  for (const p of value.split(";")) {
    const [k, v] = p.split("=");
    if (k && v !== undefined) parts.set(k.trim().toUpperCase(), v.trim());
  }
  const freq = parts.get("FREQ")?.toUpperCase();
  if (freq !== "DAILY" && freq !== "WEEKLY" && freq !== "MONTHLY" && freq !== "YEARLY") return null;
  const ints = (key: string) =>
    (parts.get(key) ?? "")
      .split(",")
      .map((x) => parseInt(x, 10))
      .filter((n) => Number.isFinite(n) && n !== 0);
  const byDay: RRule["byDay"] = [];
  for (const d of (parts.get("BYDAY") ?? "").split(",")) {
    const m = /^([+-]?\d{1,2})?(SU|MO|TU|WE|TH|FR|SA)$/i.exec(d.trim());
    if (m)
      byDay.push({
        n: m[1] ? parseInt(m[1], 10) : null,
        wd: DAYS[(m[2] ?? "").toUpperCase()] ?? 0,
      });
  }
  const interval = parseInt(parts.get("INTERVAL") ?? "1", 10);
  const count = parts.has("COUNT") ? parseInt(parts.get("COUNT") ?? "", 10) : null;
  return {
    freq,
    interval: Number.isFinite(interval) && interval > 0 ? interval : 1,
    count: count !== null && Number.isFinite(count) && count > 0 ? count : null,
    until: parts.get("UNTIL") ?? null,
    byDay,
    byMonthDay: ints("BYMONTHDAY"),
    byMonth: ints("BYMONTH").filter((m) => m >= 1 && m <= 12),
    bySetPos: ints("BYSETPOS"),
    wkst: DAYS[(parts.get("WKST") ?? "MO").toUpperCase()] ?? 1,
    unsupported: ["BYHOUR", "BYMINUTE", "BYSECOND", "BYWEEKNO", "BYYEARDAY"].some((k) =>
      parts.has(k),
    ),
  };
}

function withDate(base: Civil, year: number, month: number, day: number): Civil {
  return { ...base, year, month, day };
}

/** Days of one month a MONTHLY or YEARLY rule selects, before BYSETPOS. */
function monthDays(rule: RRule, year: number, month: number, defaultDay: number): number[] {
  const dim = daysInMonth(year, month);
  let days: number[];
  if (rule.byMonthDay.length > 0) {
    days = rule.byMonthDay.map((d) => (d > 0 ? d : dim + d + 1)).filter((d) => d >= 1 && d <= dim);
    if (rule.byDay.length > 0) {
      days = days.filter((d) =>
        rule.byDay.some(
          (b) => b.wd === weekday({ year, month, day: d, hour: 0, minute: 0, second: 0 }),
        ),
      );
    }
  } else if (rule.byDay.length > 0) {
    const set = new Set<number>();
    for (const b of rule.byDay) {
      const matching: number[] = [];
      for (let d = 1; d <= dim; d++) {
        if (weekday({ year, month, day: d, hour: 0, minute: 0, second: 0 }) === b.wd)
          matching.push(d);
      }
      if (b.n === null) matching.forEach((d) => set.add(d));
      else {
        const pick = b.n > 0 ? matching[b.n - 1] : matching[matching.length + b.n];
        if (pick !== undefined) set.add(pick);
      }
    }
    days = [...set];
  } else {
    days = defaultDay <= dim ? [defaultDay] : [];
  }
  return days.sort((a, b) => a - b);
}

function applySetPos<T>(rule: RRule, list: T[]): T[] {
  if (rule.bySetPos.length === 0) return list;
  const out: T[] = [];
  for (const p of rule.bySetPos) {
    const v = p > 0 ? list[p - 1] : list[list.length + p];
    if (v !== undefined && !out.includes(v)) out.push(v);
  }
  return out;
}

/** Candidates of period k, in order. */
function period(rule: RRule, start: Civil, k: number): Civil[] {
  const step = k * rule.interval;
  switch (rule.freq) {
    case "DAILY": {
      const c = addDays(start, step);
      if (rule.byMonth.length && !rule.byMonth.includes(c.month)) return [];
      if (rule.byMonthDay.length) {
        const dim = daysInMonth(c.year, c.month);
        if (!rule.byMonthDay.some((d) => (d > 0 ? d : dim + d + 1) === c.day)) return [];
      }
      if (rule.byDay.length && !rule.byDay.some((b) => b.wd === weekday(c))) return [];
      return [c];
    }
    case "WEEKLY": {
      const offset = (weekday(start) - rule.wkst + 7) % 7;
      const weekStart = addDays(start, step * 7 - offset);
      const wds = rule.byDay.length ? rule.byDay.map((b) => b.wd) : [weekday(start)];
      const out = [...new Set(wds)]
        .map((wd) => addDays(weekStart, (wd - rule.wkst + 7) % 7))
        .filter((c) => !rule.byMonth.length || rule.byMonth.includes(c.month))
        .sort(compareCivil);
      return applySetPos(rule, out);
    }
    case "MONTHLY": {
      const index = start.month - 1 + step;
      const year = start.year + Math.floor(index / 12);
      const month = (index % 12) + 1;
      if (rule.byMonth.length && !rule.byMonth.includes(month)) return [];
      const days = applySetPos(rule, monthDays(rule, year, month, start.day));
      return days.map((d) => withDate(start, year, month, d));
    }
    case "YEARLY": {
      const year = start.year + step;
      const hasOrdinal = rule.byDay.some((b) => b.n !== null);
      const months = rule.byMonth.length
        ? rule.byMonth
        : rule.byDay.length && !hasOrdinal
          ? [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
          : [start.month];
      if (!rule.byMonth.length && hasOrdinal)
        return [withDate(start, year, start.month, start.day)].filter(
          (c) => c.day <= daysInMonth(year, c.month),
        );
      const out: Civil[] = [];
      for (const m of [...months].sort((a, b) => a - b)) {
        for (const d of monthDays(rule, year, m, start.day)) out.push(withDate(start, year, m, d));
      }
      return applySetPos(rule, out);
    }
  }
}

export interface ExpandOptions {
  /** The instant of a wall-clock time in the event's zone. */
  toInstant: (c: Civil) => Date;
  /** The UNTIL bound as an instant (callers resolve its form). */
  until: Date | null;
  /** Occurrences starting before this are counted but not returned. */
  from: Date;
  /** Expansion stops at the first occurrence starting after this. */
  to: Date;
  maxPeriods?: number;
}

/** Occurrence start times (wall clock, event zone) of a rule, DTSTART first. */
export function expandRRule(rule: RRule, dtstart: Civil, opts: ExpandOptions): Civil[] {
  const out: Civil[] = [];
  const startMs = opts.toInstant(dtstart).getTime();
  let count = 0;
  const take = (c: Civil): boolean => {
    const t = opts.toInstant(c).getTime();
    if (opts.until && t > opts.until.getTime()) return false;
    if (t > opts.to.getTime()) return false;
    count++;
    if (t >= opts.from.getTime()) out.push(c);
    return rule.count === null || count < rule.count;
  };
  // DTSTART is always the first instance (RFC 5545 3.8.5.3), matching the rule or not.
  if (!take(dtstart) || rule.unsupported) return out;
  const maxPeriods = opts.maxPeriods ?? 20000;
  for (let k = 0; k < maxPeriods; k++) {
    for (const c of period(rule, dtstart, k)) {
      const t = opts.toInstant(c).getTime();
      if (t <= startMs) continue;
      if (!take(c)) return out;
    }
  }
  return out;
}
