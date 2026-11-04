// Event-page keywords for the probe (design 6.2): a homepage link is an event page when a path
// segment, its host's first label or its link text names one of these. Lower-cased with accents
// stripped; ordered by the region's languages, English always included. Body text is never read.

const KEYWORDS: Record<string, string[]> = {
  en: [
    "events",
    "event",
    "calendar",
    "whats-on",
    "whatson",
    "programme",
    "programs",
    "program",
    "shows",
    "concerts",
    "schedule",
    "happenings",
  ],
  de: [
    "veranstaltungen",
    "veranstaltungskalender",
    "termine",
    "kalender",
    "programm",
    "spielplan",
    "aktuelles",
  ],
  fr: ["evenements", "agenda", "programmation", "calendrier"],
  es: ["eventos", "agenda", "actividades", "programacion"],
  pt: ["eventos", "agenda", "atividades", "programacao"],
  it: ["eventi", "calendario", "agenda"],
  nl: ["evenementen", "agenda", "activiteiten"],
  pl: ["wydarzenia", "kalendarz"],
  sv: ["evenemang", "kalender"],
  da: ["arrangementer", "begivenheder", "kalender"],
};

/** Languages by country (ISO 3166-1 alpha-2); English is added to every list. */
const COUNTRY_LANGS: Record<string, string[]> = {
  DE: ["de"],
  AT: ["de"],
  CH: ["de", "fr", "it"],
  LI: ["de"],
  LU: ["fr", "de"],
  FR: ["fr"],
  BE: ["nl", "fr", "de"],
  MC: ["fr"],
  CA: ["fr"],
  ES: ["es"],
  MX: ["es"],
  AR: ["es"],
  CL: ["es"],
  CO: ["es"],
  PE: ["es"],
  UY: ["es"],
  PT: ["pt"],
  BR: ["pt"],
  IT: ["it"],
  SM: ["it"],
  NL: ["nl"],
  PL: ["pl"],
  SE: ["sv"],
  DK: ["da"],
  NO: ["da", "sv"],
};

/** Guessed paths (design 6.2 step 3) when no link matched, in the region's languages. */
const GUESSES: Record<string, string[]> = {
  en: ["/events/", "/calendar/"],
  de: ["/veranstaltungen/", "/termine/"],
  fr: ["/agenda/", "/evenements/"],
  es: ["/eventos/", "/agenda/"],
  pt: ["/eventos/", "/agenda/"],
  it: ["/eventi/", "/calendario/"],
  nl: ["/agenda/", "/evenementen/"],
  pl: ["/wydarzenia/"],
  sv: ["/evenemang/", "/kalender/"],
  da: ["/arrangementer/", "/kalender/"],
};

export function fold(s: string): string {
  return s.normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase();
}

export function languagesFor(country: string | null | undefined): string[] {
  const langs = country ? (COUNTRY_LANGS[country] ?? []) : [];
  return [...new Set([...langs, "en"])];
}

export function keywordsFor(country: string | null | undefined): string[] {
  return [...new Set(languagesFor(country).flatMap((l) => KEYWORDS[l] ?? []))];
}

export function guessedPaths(country: string | null | undefined): string[] {
  const langs = languagesFor(country);
  // The region's own language first, English after.
  const ordered = [...langs.filter((l) => l !== "en"), "en"];
  return [...new Set(ordered.flatMap((l) => GUESSES[l] ?? []))];
}

/**
 * How strongly a link names an event page: 3 for a path segment or the host's first label
 * that is a keyword (or starts with one, "events-calendar"), 2 for a keyword word in the link
 * text, 0 otherwise.
 */
export function keywordStrength(url: string, text: string, keywords: string[]): number {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return 0;
  }
  const words = (s: string) =>
    fold(s)
      .replace(/['\u2019]/g, "")
      .split(/[^a-z0-9]+/)
      .filter(Boolean);
  const segs = u.pathname
    .split("/")
    .filter(Boolean)
    .map((s) => fold(decodeURIComponentSafe(s)).replace(/\.(html?|php|aspx?)$/, ""));
  const first = fold(u.hostname.split(".")[0] ?? "");
  const hit = (seg: string) =>
    keywords.some(
      (k) =>
        seg === k || seg.startsWith(`${k}-`) || seg.startsWith(`${k}_`) || seg.endsWith(`-${k}`),
    );
  if (hit(first) || segs.some(hit)) return 3;
  const t = words(text).join("-");
  if (t && keywords.some((k) => t === k || `-${t}-`.includes(`-${k}-`))) return 2;
  return 0;
}

function decodeURIComponentSafe(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}
