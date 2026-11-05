import { bandText, type DistanceUnit } from "../feed/distance";
import type { Reason } from "./schemas";

/**
 * Reason chips (RECS_DESIGN section 5.1). The server picks the reasons and their order; the
 * client only turns codes into words and keeps to two chips. `from_source` is the imported
 * listing's attribution (D-020): it is always shown and never counts toward the two.
 *
 *   reasonLabel({ code: "near", band: "1-5 mi" })      // "1-5 mi away"
 *   splitReasons(reasons)                             // { chips: [two at most], attribution }
 *   whyLines(reasons)                                 // full sentences for "Why am I seeing this?"
 */

export const MAX_CHIPS = 2;

const WHEN_LABELS = {
  tonight: "Tonight",
  today: "Today",
  tomorrow: "Tomorrow",
  this_weekend: "This weekend",
} as const;

/**
 * A distance band in words, in the viewer's unit: "<1 mi" reads "Under 1 mi", "1-5 mi" stays
 * short; in kilometres "Under 2 km" and "2-8 km".
 */
function bandWords(band: string, unit: DistanceUnit): string {
  if (band === "<1 mi") return bandText(band, unit);
  return unit === "km" ? bandText(band, unit).replace(" to ", "-") : band;
}

function plural(n: number, one: string, many: string): string {
  return n === 1 ? one : many;
}

/** The chip copy for one reason. */
export function reasonLabel(r: Reason, unit: DistanceUnit = "mi"): string {
  switch (r.code) {
    case "people_met_going":
      return `${r.n} ${plural(r.n, "person you've met is", "people you've met are")} going`;
    case "like_hub":
      return `Like ${r.hub_name}`;
    case "like_plan":
      return `Like ${r.title}`;
    case "in_your_hub":
      return `In ${r.hub_name}`;
    case "same_hub":
      return `Also ${r.hub_name}`;
    case "when":
      return WHEN_LABELS[r.when];
    case "near":
      return r.band === "online" ? "Online" : `${bandWords(r.band, unit)} away`;
    case "free":
      return "Free";
    case "popular":
      return "Filling up";
    case "from_source":
      return `From ${r.source_name}`;
    case "teaches_your_hub":
      return `Coaches ${r.hub_name}`;
    case "online":
      return "Online";
    case "rated":
      return `${r.avg.toFixed(1)} from ${r.n} ${plural(r.n, "review", "reviews")}`;
    case "went_to_same":
      return `You both went to ${r.title}`;
    case "same_chapter":
      return `Both in ${r.chapter_name}`;
    case "going_to_same":
      return `Also going to ${r.title}`;
    case "nearby_plans":
      return `${r.n} ${plural(r.n, "plan", "plans")} near you this month`;
    case "coming_up":
      return "Coming up near you";
  }
}

/** One sentence per reason, for the "Why am I seeing this?" sheet. */
export function reasonSentence(r: Reason, unit: DistanceUnit = "mi"): string {
  switch (r.code) {
    case "people_met_going":
      return `${r.n} ${plural(r.n, "person you've met is", "people you've met are")} going.`;
    case "like_hub":
      return `It's like ${r.hub_name}, a hub you're in.`;
    case "like_plan":
      return `It's like ${r.title}, a plan you went to.`;
    case "in_your_hub":
      return `It's in ${r.hub_name}, a hub you're in.`;
    case "same_hub":
      return `It's also in ${r.hub_name}.`;
    case "when":
      return `It's ${WHEN_LABELS[r.when].toLowerCase()}.`;
    case "near":
      return r.band === "online"
        ? "It's online."
        : `It's ${bandWords(r.band, unit).toLowerCase()} away.`;
    case "free":
      return "It's free.";
    case "popular":
      return "It's filling up.";
    case "from_source":
      return `It's listed from ${r.source_name}.`;
    case "teaches_your_hub":
      return `They coach ${r.hub_name}, a hub you're in.`;
    case "online":
      return "They coach online.";
    case "rated":
      return `They have ${r.avg.toFixed(1)} stars from ${r.n} ${plural(r.n, "review", "reviews")}.`;
    case "went_to_same":
      return `You both went to ${r.title}.`;
    case "same_chapter":
      return `You're both in ${r.chapter_name}.`;
    case "going_to_same":
      return `You're both going to ${r.title}.`;
    case "nearby_plans":
      return `It has ${r.n} ${plural(r.n, "plan", "plans")} near you this month.`;
    case "coming_up":
      return "It's coming up near you.";
  }
}

export interface SplitReasons {
  /** At most two chips, in the server's order, never the attribution. */
  chips: Reason[];
  /** The imported listing's source, shown on its own; null for everything else. */
  attribution: Extract<Reason, { code: "from_source" }> | null;
}

export function splitReasons(reasons: readonly Reason[]): SplitReasons {
  const chips: Reason[] = [];
  let attribution: SplitReasons["attribution"] = null;
  const seen = new Set<string>();
  for (const r of reasons) {
    if (r.code === "from_source") {
      attribution ??= r;
      continue;
    }
    const label = reasonLabel(r);
    if (seen.has(label) || chips.length >= MAX_CHIPS) continue;
    seen.add(label);
    chips.push(r);
  }
  return { chips, attribution };
}

/**
 * The sentences behind a card, chips first and then the attribution. A recommendation with no
 * reason still says how it was picked, without any score or personal detail.
 */
export function whyLines(reasons: readonly Reason[], unit: DistanceUnit = "mi"): string[] {
  const { chips, attribution } = splitReasons(reasons);
  const lines = chips.map((r) => reasonSentence(r, unit));
  if (attribution) lines.push(reasonSentence(attribution));
  if (lines.length === 0) lines.push("It's coming up near you.");
  return lines;
}

/** The closing line of the "Why am I seeing this?" sheet. */
export function whyNote(kind: "personal" | "rules" | "similar" | "people"): string {
  switch (kind) {
    case "personal":
      return "Suggestions use your hubs and your plans, plus how close and how soon things are. You can turn this off in You, under Privacy and safety.";
    case "rules":
      return "Personalization is off, so suggestions use only how close and how soon things are.";
    case "similar":
      return "Similar plans are picked from what this plan is about, how close and how soon. Nothing about you is used.";
    case "people":
      return "People are suggested only from plans and chapters you share. You can stop being suggested in You, under Privacy and safety.";
  }
}
