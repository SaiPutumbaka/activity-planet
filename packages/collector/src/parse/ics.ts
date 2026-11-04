// iCalendar feeds (RFC 5545): VEVENTs to RawEvents, recurring events expanded inside the run
// window. Zones: UTC (Z), TZID (IANA names, mozilla-style prefixes, VTIMEZONE X-LIC-LOCATION
// and common Windows names), floating times in X-WR-TIMEZONE or the region's zone. VTIMEZONE
// rule bodies are not evaluated; the IANA database is the source of truth for offsets.
// RECURRENCE-ID overrides replace their instance, EXDATE removes, RDATE adds; CLASS:PRIVATE
// and CONFIDENTIAL events are left out.

import type { RawEvent } from "../types.ts";
import { type Civil, resolveZone, zonedToUtc } from "../util/time.ts";
import { httpsUrl } from "../util/url.ts";
import { expandRRule, parseRRule } from "./rrule.ts";

interface Prop {
  name: string;
  params: Record<string, string>;
  value: string;
}

interface Component {
  type: string;
  props: Prop[];
  children: Component[];
}

/** RFC 5545 3.1: a CRLF followed by a space or tab continues the previous line. */
export function unfold(text: string): string[] {
  return text
    .replace(/^\uFEFF/, "")
    .replace(/\r\n|\r/g, "\n")
    .replace(/\n[ \t]/g, "")
    .split("\n")
    .filter((l) => l.trim() !== "");
}

/** "DTSTART;TZID="America/New_York";VALUE=DATE-TIME:20261110T190000". */
export function parseLine(line: string): Prop | null {
  let i = 0;
  let name = "";
  while (i < line.length && line[i] !== ";" && line[i] !== ":") name += line[i++];
  const params: Record<string, string> = {};
  while (i < line.length && line[i] === ";") {
    i++;
    let key = "";
    while (i < line.length && line[i] !== "=" && line[i] !== ":" && line[i] !== ";")
      key += line[i++];
    let val = "";
    if (line[i] === "=") {
      i++;
      if (line[i] === '"') {
        i++;
        while (i < line.length && line[i] !== '"') val += line[i++];
        i++;
      }
      while (i < line.length && line[i] !== ";" && line[i] !== ":") val += line[i++];
    }
    params[key.trim().toUpperCase()] = val;
  }
  if (line[i] !== ":") return null;
  return { name: name.trim().toUpperCase(), params, value: line.slice(i + 1) };
}

export function parseComponents(text: string): Component {
  const root: Component = { type: "ROOT", props: [], children: [] };
  const stack: Component[] = [root];
  for (const line of unfold(text)) {
    const prop = parseLine(line);
    if (!prop) continue;
    const top = stack[stack.length - 1] ?? root;
    if (prop.name === "BEGIN") {
      const c: Component = { type: prop.value.trim().toUpperCase(), props: [], children: [] };
      top.children.push(c);
      stack.push(c);
    } else if (prop.name === "END") {
      if (stack.length > 1) stack.pop();
    } else {
      top.props.push(prop);
    }
  }
  return root;
}

/** RFC 5545 3.3.11 TEXT unescaping. */
export function unescapeText(value: string): string {
  return value.replace(/\\([\\;,nN])/g, (_m, c: string) => (c === "n" || c === "N" ? "\n" : c));
}

interface IcsTime {
  civil: Civil;
  zone: string;
  dateOnly: boolean;
}

function parseIcsTime(prop: Prop, zoneFor: (tzid: string | undefined) => string): IcsTime | null {
  const v = prop.value.trim();
  const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$/.exec(v);
  if (!m) {
    const d = new Date(v);
    if (Number.isNaN(d.getTime())) return null;
    return { civil: civilOfUtc(d), zone: "UTC", dateOnly: false };
  }
  const dateOnly = m[4] === undefined || prop.params.VALUE === "DATE";
  const civil: Civil = {
    year: Number(m[1]),
    month: Number(m[2]),
    day: Number(m[3]),
    hour: dateOnly ? 0 : Number(m[4]),
    minute: dateOnly ? 0 : Number(m[5]),
    second: dateOnly ? 0 : Number(m[6] ?? 0),
  };
  return { civil, zone: m[7] ? "UTC" : zoneFor(prop.params.TZID), dateOnly };
}

function civilOfUtc(d: Date): Civil {
  return {
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    hour: d.getUTCHours(),
    minute: d.getUTCMinutes(),
    second: d.getUTCSeconds(),
  };
}

/** zonedToUtc results by (zone, wall time): Intl lookups dominate expansion cost. */
const instantCache = new Map<string, number>();
const INSTANT_CACHE_MAX = 100_000;

export function instantOf(civil: Civil, zone: string): Date {
  if (zone === "UTC")
    return new Date(
      Date.UTC(civil.year, civil.month - 1, civil.day, civil.hour, civil.minute, civil.second),
    );
  const key = `${zone}|${civil.year}-${civil.month}-${civil.day}T${civil.hour}:${civil.minute}:${civil.second}`;
  const hit = instantCache.get(key);
  if (hit !== undefined) return new Date(hit);
  const at = zonedToUtc(civil, zone);
  if (instantCache.size >= INSTANT_CACHE_MAX) instantCache.clear();
  instantCache.set(key, at.getTime());
  return at;
}

/** RFC 5545 3.3.6 DURATION ("PT1H30M", "P1D", "-PT15M") in milliseconds, or null. */
export function parseDuration(value: string): number | null {
  const m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/i.exec(
    value.trim(),
  );
  if (!m) return null;
  const [, sign, w, d, h, mi, s] = m;
  const ms =
    ((Number(w ?? 0) * 7 + Number(d ?? 0)) * 86400 +
      Number(h ?? 0) * 3600 +
      Number(mi ?? 0) * 60 +
      Number(s ?? 0)) *
    1000;
  return sign === "-" ? -ms : ms;
}

export interface IcsOptions {
  sourceUrl: string;
  /** Zone for floating times when the calendar names none. */
  defaultZone: string;
  windowStart: Date;
  windowEnd: Date;
}

function first(props: Prop[], name: string): Prop | undefined {
  return props.find((p) => p.name === name);
}

function all(props: Prop[], name: string): Prop[] {
  return props.filter((p) => p.name === name);
}

const MAX_INSTANCES_PER_EVENT = 200;
/** Recurrence work allowed per file (see ExpandOptions.budget). */
export const EXPANSION_BUDGET = 50_000;

export function parseIcs(text: string, opts: IcsOptions): RawEvent[] {
  const root = parseComponents(text);
  const cal = root.children.find((c) => c.type === "VCALENDAR") ?? root;
  const calZone = resolveZone(first(cal.props, "X-WR-TIMEZONE")?.value) ?? opts.defaultZone;

  // VTIMEZONE TZIDs that are not IANA names but say which one they mean.
  const tzAliases = new Map<string, string>();
  for (const vt of cal.children.filter((c) => c.type === "VTIMEZONE")) {
    const id = first(vt.props, "TZID")?.value.trim();
    const loc = resolveZone(first(vt.props, "X-LIC-LOCATION")?.value);
    if (id && loc) tzAliases.set(id, loc);
  }
  const zoneFor = (tzid: string | undefined): string => {
    if (!tzid) return calZone;
    return resolveZone(tzid) ?? tzAliases.get(tzid.trim()) ?? calZone;
  };

  const events = cal.children.filter((c) => c.type === "VEVENT");
  const masters = new Map<string, Component>();
  const overrides = new Map<string, Map<number, Component>>();
  const singles: Component[] = [];
  for (const ev of events) {
    const uid = first(ev.props, "UID")?.value.trim();
    const rid = first(ev.props, "RECURRENCE-ID");
    if (uid && rid) {
      const t = parseIcsTime(rid, zoneFor);
      if (!t) continue;
      const map = overrides.get(uid) ?? new Map<number, Component>();
      map.set(instantOf(t.civil, t.zone).getTime(), ev);
      overrides.set(uid, map);
    } else if (uid) {
      if (!masters.has(uid)) masters.set(uid, ev);
    } else {
      singles.push(ev);
    }
  }

  const out: RawEvent[] = [];
  const budget = { left: EXPANSION_BUDGET };
  const inWindow = (s: Date, e: Date) =>
    e.getTime() > opts.windowStart.getTime() && s.getTime() < opts.windowEnd.getTime();

  /** Adds the instance when it is public and in the window; says whether it did. */
  const emit = (
    ev: Component,
    start: Date,
    end: Date,
    allDay: boolean,
    id: string | null,
  ): boolean => {
    const cls = first(ev.props, "CLASS")?.value.trim().toUpperCase();
    if (cls === "PRIVATE" || cls === "CONFIDENTIAL") return false;
    if (!inWindow(start, end)) return false;
    const text = (name: string) => unescapeText(first(ev.props, name)?.value ?? "").trim();
    const geo = /^\s*(-?\d+(?:\.\d+)?)\s*[;,]\s*(-?\d+(?:\.\d+)?)\s*$/.exec(
      first(ev.props, "GEO")?.value ?? "",
    );
    const description = text("DESCRIPTION") || text("X-ALT-DESC");
    const urlProp = first(ev.props, "URL")?.value.trim();
    const url = httpsUrl(urlProp) ?? httpsUrl(/https:\/\/[^\s<>"')\]]+/.exec(description)?.[0]);
    const organizer = first(ev.props, "ORGANIZER");
    const categories = all(ev.props, "CATEGORIES")
      .flatMap((p) => p.value.split(/(?<!\\),/))
      .map((c) => unescapeText(c).trim())
      .filter(Boolean);
    const status = first(ev.props, "STATUS")?.value.trim().toUpperCase();
    out.push({
      lane: "feed",
      uid: id,
      title: text("SUMMARY"),
      description,
      url,
      start: start.toISOString(),
      end: allDay ? new Date(end.getTime() - 60_000).toISOString() : end.toISOString(),
      allDay,
      location: text("LOCATION"),
      lat: geo ? Number(geo[1]) : null,
      lng: geo ? Number(geo[2]) : null,
      cancelled: status === "CANCELLED",
      categories,
      host: organizer?.params.CN ? organizer.params.CN.replace(/^"|"$/g, "") : null,
      sourceUrl: opts.sourceUrl,
    });
    return true;
  };

  /** Start, end and all-day of a component, or null when it has no usable DTSTART. */
  const timesOf = (ev: Component) => {
    const ds = first(ev.props, "DTSTART");
    if (!ds) return null;
    const start = parseIcsTime(ds, zoneFor);
    if (!start) return null;
    const startAt = instantOf(start.civil, start.zone);
    const de = first(ev.props, "DTEND");
    const dur = first(ev.props, "DURATION");
    let durationMs: number;
    if (de) {
      const end = parseIcsTime(de, zoneFor);
      durationMs = end ? instantOf(end.civil, end.zone).getTime() - startAt.getTime() : 0;
    } else if (dur) {
      durationMs = parseDuration(dur.value) ?? 0;
    } else {
      durationMs = start.dateOnly ? 86_400_000 : 0;
    }
    if (durationMs < 0) durationMs = 0;
    return { start, startAt, durationMs };
  };

  for (const ev of singles) {
    const t = timesOf(ev);
    if (!t) continue;
    emit(
      ev,
      t.startAt,
      new Date(t.startAt.getTime() + (t.durationMs || (t.start.dateOnly ? 86_400_000 : 0))),
      t.start.dateOnly,
      null,
    );
  }

  for (const [uid, ev] of masters) {
    const t = timesOf(ev);
    if (!t) continue;
    const own = overrides.get(uid) ?? new Map<number, Component>();
    const rruleProp = first(ev.props, "RRULE");
    const rdates = all(ev.props, "RDATE");
    const rule = rruleProp ? parseRRule(rruleProp.value) : null;
    const zone = t.start.zone;
    const toInstant = (c: Civil) => instantOf(c, zone);

    if (!rule && rdates.length === 0) {
      const override = own.get(t.startAt.getTime());
      const target = override ?? ev;
      const tt = override ? (timesOf(override) ?? t) : t;
      emit(
        target,
        tt.startAt,
        new Date(tt.startAt.getTime() + tt.durationMs),
        tt.start.dateOnly,
        uid,
      );
      continue;
    }

    let until: Date | null = null;
    if (rule?.until) {
      const u = parseIcsTime({ name: "UNTIL", params: {}, value: rule.until }, () => zone);
      if (u) {
        until = u.dateOnly
          ? instantOf({ ...u.civil, hour: 23, minute: 59, second: 59 }, zone)
          : instantOf(u.civil, u.zone === "UTC" ? "UTC" : zone);
      }
    }
    const from = new Date(opts.windowStart.getTime() - Math.max(t.durationMs, 0));
    const starts = new Map<number, Date>();
    const civils = rule
      ? expandRRule(rule, t.start.civil, {
          toInstant,
          until,
          from,
          to: opts.windowEnd,
          budget,
        })
      : [t.start.civil];
    for (const c of civils) {
      const at = toInstant(c);
      starts.set(at.getTime(), at);
    }
    for (const rd of rdates) {
      for (const v of rd.value.split(",")) {
        const r = parseIcsTime({ ...rd, value: v }, zoneFor);
        if (!r) continue;
        const at = instantOf(r.civil, r.zone);
        // Past RDATEs are dropped here so they cannot use up the per-event cap.
        if (at.getTime() <= opts.windowEnd.getTime() && at.getTime() > from.getTime())
          starts.set(at.getTime(), at);
      }
    }
    for (const ex of all(ev.props, "EXDATE")) {
      for (const v of ex.value.split(",")) {
        const x = parseIcsTime({ ...ex, value: v }, zoneFor);
        if (!x) continue;
        if (x.dateOnly) {
          // A date EXDATE removes every instance that day in the event's zone.
          for (const key of [...starts.keys()]) {
            const dayStart = instantOf(x.civil, zone).getTime();
            if (key >= dayStart && key < dayStart + 86_400_000) starts.delete(key);
          }
        } else {
          starts.delete(instantOf(x.civil, x.zone).getTime());
        }
      }
    }

    // Only instances that are actually emitted count toward the cap.
    let n = 0;
    for (const at of [...starts.values()].sort((a, b) => a.getTime() - b.getTime())) {
      if (n >= MAX_INSTANCES_PER_EVENT) break;
      if (at.getTime() <= from.getTime() && !own.has(at.getTime())) continue;
      const override = own.get(at.getTime());
      let emitted = false;
      if (override) {
        const ot = timesOf(override);
        if (ot)
          emitted = emit(
            override,
            ot.startAt,
            new Date(ot.startAt.getTime() + ot.durationMs),
            ot.start.dateOnly,
            `${uid}#${at.toISOString()}`,
          );
        own.delete(at.getTime());
      } else {
        emitted = emit(
          ev,
          at,
          new Date(at.getTime() + t.durationMs),
          t.start.dateOnly,
          `${uid}#${at.toISOString()}`,
        );
      }
      if (emitted) n++;
    }
  }
  return out;
}
