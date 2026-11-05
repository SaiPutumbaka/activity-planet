/**
 * The database's place-matching rules, for places that only a static tile file holds (D-042
 * slice 11, AUTO_COVERAGE_DESIGN §4.5): pg_trgm's similarity, and the name search places_in_view
 * runs (`lower(name || ' ' || locality) like '%text%'`). The place-files Edge Function carries
 * the same similarity (supabase/functions/place-files/files.ts); both are tested against values
 * from Postgres.
 */

/**
 * pg_trgm's trigram set (show_trgm): words are runs of letters and digits, each padded with two
 * spaces in front and one behind; every three-character window is a trigram.
 */
export function trigrams(text: string): Set<string> {
  const out = new Set<string>();
  for (const word of text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []) {
    const chars = Array.from(`  ${word} `);
    for (let i = 0; i + 3 <= chars.length; i++) out.add(chars.slice(i, i + 3).join(""));
  }
  return out;
}

/** pg_trgm similarity(a, b): shared trigrams over all distinct trigrams. */
export function similarity(a: string, b: string): number {
  const ta = trigrams(a);
  const tb = trigrams(b);
  if (!ta.size || !tb.size) return 0;
  let common = 0;
  for (const t of ta) if (tb.has(t)) common++;
  return common / (ta.size + tb.size - common);
}

/** add_place's duplicate rule (migration 34) and the venue rule (migration 36): 0.45. */
export const CLOSE_NAME = 0.45;

/** The same or a close name, as the database compares them (lower-cased). */
export function sameOrCloseName(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase() || similarity(a, b) >= CLOSE_NAME;
}

/** Search text as places_in_view's p_query takes it: trimmed, 2 to 60 characters, else null. */
export function placeSearchNeedle(text: string): string | null {
  const q = text.trim().toLowerCase();
  return q.length >= 2 && q.length <= 60 ? q : null;
}

/** places_in_view's match: the needle inside "name locality", lower-cased. */
export function placeSearchMatches(needle: string, name: string, locality = ""): boolean {
  return `${name} ${locality}`.toLowerCase().includes(needle);
}
