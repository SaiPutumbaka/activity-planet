/**
 * Generate supabase/seed/hubs.sql from packages/core/src/catalog/hub-catalog.ts plus the
 * campus-life categories, so the hubs table is seeded from one source of truth.
 *
 * Run:  node --experimental-strip-types scripts/gen-hub-seed.mts
 *
 * Rules applied here, in order: catalog hubs, then campus-life hubs (a collision with a catalog
 * hub must be listed in MERGE_INTO_CATALOG or the script fails), then duplicate merges (MERGE),
 * category overrides, 21+ and campus flags, search aliases (every ALIASES key must resolve).
 */
import { writeFileSync, mkdirSync } from "node:fs";
import { HUB_CATALOG } from "../packages/core/src/catalog/hub-catalog.ts";

type Category = {
  slug: string;
  name: string;
  colorKey: string;
  sort: number;
  isSensitive?: boolean;
  scope?: "general" | "campus";
  minAge?: 18 | 21;
};
type Hub = {
  slug: string;
  name: string;
  category: string;
  emoji: string;
  aliases: string[];
  scope: "general" | "campus";
  minAge: 18 | 21;
};

function slugify(input: string): string {
  return input
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/&/g, " and ")
    .replace(/\+/g, " plus")
    .replace(/[^a-zA-Z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase();
}

// Catalog categories (from the 2026-07 brainstorm) plus campus-life categories (D-023).
const CATEGORY_META: Record<string, { colorKey: string; sort: number }> = {
  "Team Sports": { colorKey: "sport", sort: 10 },
  "Individual & Racquet Sports": { colorKey: "sport", sort: 11 },
  "Combat Sports & Martial Arts": { colorKey: "sport", sort: 12 },
  "Running, Cycling & Endurance": { colorKey: "endurance", sort: 13 },
  "Fitness, Gym & Wellness": { colorKey: "wellness", sort: 14 },
  "Outdoors & Adventure": { colorKey: "outdoors", sort: 15 },
  "Water Sports": { colorKey: "outdoors", sort: 16 },
  "Winter Sports": { colorKey: "outdoors", sort: 17 },
  "Golf, Precision & Target Sports": { colorKey: "sport", sort: 18 },
  "Tabletop, Card & Board Games": { colorKey: "games", sort: 20 },
  "Video Gaming & Esports": { colorKey: "games", sort: 21 },
  "Arts, Crafts & Making": { colorKey: "arts", sort: 30 },
  "Music & Performance": { colorKey: "arts", sort: 31 },
  "Food & Drink": { colorKey: "food", sort: 40 },
  "Movies, TV & Fandom": { colorKey: "fandom", sort: 50 },
  "Books, Writing & Learning": { colorKey: "learning", sort: 60 },
  "Collecting, Tech & Automotive": { colorKey: "tech", sort: 61 },
  "Social, Lifestyle & Community": { colorKey: "social", sort: 70 },
};

const CAMPUS_LIFE: Array<{
  category: Category;
  hubs: Array<{ name: string; emoji: string; aliases?: string[] }>;
}> = [
  {
    category: {
      slug: slugify("Careers & Networking"),
      name: "Careers & Networking",
      colorKey: "learning",
      sort: 80,
    },
    hubs: [
      { name: "Career Events", emoji: "💼", aliases: ["career fair", "recruiting", "employer"] },
      { name: "Networking Nights", emoji: "🤝", aliases: ["mixer", "networking mixer"] },
      { name: "Internships & Jobs", emoji: "📄", aliases: ["handshake", "hiring"] },
      { name: "Entrepreneurship", emoji: "🚀", aliases: ["startup", "founders", "pitch"] },
      { name: "Resume & Interview Prep", emoji: "📝" },
    ],
  },
  {
    category: {
      slug: slugify("Academics & Study"),
      name: "Academics & Study",
      colorKey: "learning",
      sort: 81,
    },
    hubs: [
      { name: "Study Sessions", emoji: "📚", aliases: ["study group", "quiet study", "library"] },
      { name: "Tutoring", emoji: "🧑‍🏫" },
      {
        name: "Workshops & Skill Builders",
        emoji: "🛠️",
        aliases: ["workshop", "excel", "training"],
      },
      { name: "Lectures & Talks", emoji: "🎤", aliases: ["speaker", "seminar", "panel"] },
      { name: "Research & Labs", emoji: "🔬" },
      { name: "Graduate School Prep", emoji: "🎓" },
    ],
  },
  {
    category: {
      slug: slugify("Culture & Identity"),
      name: "Culture & Identity",
      colorKey: "social",
      sort: 82,
      isSensitive: true,
    },
    hubs: [
      { name: "Cultural Celebrations", emoji: "🌍", aliases: ["heritage month", "festival"] },
      { name: "International Students", emoji: "🛂" },
      { name: "Black Student Life", emoji: "✊🏾" },
      { name: "Latinx Student Life", emoji: "🎉" },
      { name: "Asian & Pacific Islander Life", emoji: "🏮" },
      { name: "LGBTQ+ Community", emoji: "🏳️‍🌈", aliases: ["pride", "queer"] },
      { name: "Women in Leadership", emoji: "👩‍💼" },
      { name: "First-Generation Students", emoji: "🌱" },
      { name: "Veterans & Military", emoji: "🎖️" },
    ],
  },
  {
    category: {
      slug: slugify("Faith & Spirituality"),
      name: "Faith & Spirituality",
      colorKey: "social",
      sort: 83,
      isSensitive: true,
    },
    hubs: [
      { name: "Christian Fellowship", emoji: "✝️" },
      { name: "Muslim Student Life", emoji: "☪️" },
      { name: "Jewish Student Life", emoji: "✡️" },
      { name: "Hindu Community", emoji: "🕉️" },
      { name: "Sikh Community", emoji: "🪯" },
      { name: "Buddhist Community", emoji: "☸️" },
      { name: "Interfaith Dialogue", emoji: "🕊️" },
    ],
  },
  {
    category: {
      slug: slugify("Service & Causes"),
      name: "Service & Causes",
      colorKey: "outdoors",
      sort: 84,
    },
    hubs: [
      { name: "Volunteering", emoji: "🙌", aliases: ["community service", "service day"] },
      { name: "Fundraisers", emoji: "💝" },
      { name: "Sustainability & Climate", emoji: "♻️", aliases: ["environment", "green"] },
      { name: "Civic Engagement & Voting", emoji: "🗳️", aliases: ["politics", "advocacy"] },
      { name: "Mentoring & Tutoring Kids", emoji: "🧒" },
      { name: "Animal Rescue", emoji: "🐾" },
    ],
  },
  {
    category: {
      slug: slugify("Wellness & Support"),
      name: "Wellness & Support",
      colorKey: "wellness",
      sort: 85,
      isSensitive: true,
    },
    hubs: [
      { name: "Mental Health & Peer Support", emoji: "💚", aliases: ["counseling", "wellbeing"] },
      { name: "Sober & Substance-Free Fun", emoji: "🧃" },
      { name: "Disability & Accessibility", emoji: "♿" },
      { name: "Parents & Caregivers", emoji: "👨‍👧" },
      { name: "Sleep, Stress & Balance", emoji: "🌙" },
    ],
  },
  {
    category: {
      slug: slugify("Campus Life & Free Food"),
      name: "Campus Life & Free Food",
      colorKey: "food",
      sort: 86,
      scope: "campus",
    },
    hubs: [
      { name: "Free Food", emoji: "🍕", aliases: ["pizza", "snacks", "refreshments"] },
      {
        name: "Campus Traditions & Spirit",
        emoji: "🎉",
        aliases: ["homecoming", "pep rally", "spirit", "campus life"],
      },
      { name: "Residence Hall Events", emoji: "🏠", aliases: ["dorm", "housing", "res life"] },
      {
        name: "New Student Welcome",
        emoji: "👋",
        aliases: ["orientation", "welcome week", "freshman"],
      },
      { name: "Game Room & Hangouts", emoji: "🎱", aliases: ["student center", "lounge"] },
      { name: "Transfer & Commuter Students", emoji: "🚆" },
      {
        name: "Campus Jobs & Involvement Fairs",
        emoji: "📋",
        aliases: ["involvement fair", "org fair"],
      },
    ],
  },
  {
    category: {
      slug: slugify("Nightlife & 21+"),
      name: "Nightlife & 21+",
      colorKey: "nightlife",
      sort: 90,
      minAge: 21,
    },
    hubs: [
      { name: "Bar Trivia", emoji: "🍻", aliases: ["trivia night", "pub quiz"] },
      { name: "Brewery Runs & Tours", emoji: "🍺" },
      { name: "Wine Nights", emoji: "🍷", aliases: ["wine tasting", "wine bar"] },
      { name: "Cocktail Nights", emoji: "🍸" },
      { name: "Clubs & DJ Nights", emoji: "🪩", aliases: ["club", "dj", "nightclub"] },
      { name: "Comedy Clubs", emoji: "🎙️", aliases: ["comedy night", "stand-up"] },
      { name: "Live Music Venues", emoji: "🎸", aliases: ["concert", "gig", "show"] },
    ],
  },
];

// A campus-life hub that collides with a catalog hub must be listed here: keep the catalog entry,
// optionally move it to the campus-life category, merge aliases.
const MERGE_INTO_CATALOG: Record<string, { category?: string }> = {
  volunteering: { category: slugify("Service & Causes") },
};

// Duplicate hubs in the 2026-07 catalog: duplicate slug -> canonical slug. The duplicate's name
// becomes an alias of the canonical hub. Skipped (with a warning) if either side is missing.
const MERGE: Record<string, string> = {
  "ping-pong": "table-tennis",
  "road-running": "running",
  "chess-club": "chess",
  "trivia-games": "trivia",
  "trivia-night": "trivia",
  "anime-fandom": "anime",
  "networking-mixer": "networking-nights",
  "comedy-night": "comedy-clubs",
  "college-campus-life": "campus-traditions-and-spirit",
  "knitting-circle": "knitting",
  "cooking-class": "cooking",
  "poker-night": "poker",
  "movie-night": "movies",
  "bingo-night": "bingo",
  "debate-club": "debate",
  "tabletop-role-playing-games": "tabletop-rpg",
};

const CATEGORY_OVERRIDES: Record<string, string> = {
  running: slugify("Running, Cycling & Endurance"),
};

// Alcohol-centred hubs outside the Nightlife category are still 21+ (D-027).
const MIN_AGE_21 = new Set([
  "wine-tasting",
  "beer-tasting",
  "craft-beer-tasting",
  "pub-crawl",
  "home-brewing",
  "cocktail-making",
  "mixology",
]);

// Search synonyms. Every key must resolve to a hub slug after merges.
const ALIASES: Record<string, string[]> = {
  "table-tennis": ["ping pong"],
  pool: ["billiards", "8 ball", "nine ball"],
  running: ["jogging", "run club"],
  esports: ["gaming", "competitive gaming"],
  "pc-gaming": ["gaming"],
  basketball: ["hoops", "pickup basketball", "pickup"],
  soccer: ["football (soccer)", "futbol", "pickup soccer"],
  "american-football": ["football"],
  volleyball: ["indoor volleyball", "pickup volleyball"],
  anime: ["manga", "anime club", "anime night"],
  chess: ["chess club"],
  "board-game-night": ["board games", "tabletop"],
  "trading-card-games": ["tcg", "magic the gathering", "pokemon", "yu-gi-oh"],
  "coding-and-programming": ["coding", "hackathon", "dev", "software"],
  swimming: ["swim club"],
  tennis: ["pickup tennis"],
};

function sqlString(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

function sqlTextArray(values: string[]): string {
  if (values.length === 0) return "'{}'::text[]";
  return `array[${values.map(sqlString).join(", ")}]`;
}

const warnings: string[] = [];
const categories: Category[] = [];
const hubs: Hub[] = [];
const bySlug = () => new Map(hubs.map((h) => [h.slug, h]));

for (const group of HUB_CATALOG) {
  const meta = CATEGORY_META[group.category];
  if (!meta) throw new Error(`No category meta for "${group.category}"`);
  const slug = slugify(group.category);
  categories.push({ slug, name: group.category, colorKey: meta.colorKey, sort: meta.sort });
  for (const hub of group.hubs) {
    const hubSlug = slugify(hub.name);
    if (bySlug().has(hubSlug))
      throw new Error(`Catalog slug collision: "${hub.name}" -> ${hubSlug}`);
    hubs.push({
      slug: hubSlug,
      name: hub.name,
      category: slug,
      emoji: hub.emoji,
      aliases: [],
      scope: "general",
      minAge: 18,
    });
  }
}

for (const group of CAMPUS_LIFE) {
  categories.push(group.category);
  for (const hub of group.hubs) {
    const hubSlug = slugify(hub.name);
    const existing = bySlug().get(hubSlug);
    if (existing) {
      const rule = MERGE_INTO_CATALOG[hubSlug];
      if (!rule) {
        throw new Error(
          `Campus-life hub "${hub.name}" collides with catalog hub "${existing.name}" (${hubSlug}); rename it or add it to MERGE_INTO_CATALOG`,
        );
      }
      if (rule.category) existing.category = rule.category;
      existing.aliases = Array.from(new Set([...existing.aliases, ...(hub.aliases ?? [])]));
      warnings.push(`merged campus-life "${hub.name}" into catalog entry (${existing.category})`);
      continue;
    }
    hubs.push({
      slug: hubSlug,
      name: hub.name,
      category: group.category.slug,
      emoji: hub.emoji,
      aliases: hub.aliases ?? [],
      scope: group.category.scope ?? "general",
      minAge: group.category.minAge ?? 18,
    });
  }
}

// Duplicate merges
for (const [dup, canonical] of Object.entries(MERGE)) {
  const map = bySlug();
  const d = map.get(dup);
  const c = map.get(canonical);
  if (!d || !c) {
    warnings.push(
      `MERGE skipped: ${dup} -> ${canonical} (${!d ? "duplicate missing" : "canonical missing"})`,
    );
    continue;
  }
  c.aliases = Array.from(new Set([...c.aliases, d.name.toLowerCase(), ...d.aliases]));
  hubs.splice(hubs.indexOf(d), 1);
}

for (const [slug, category] of Object.entries(CATEGORY_OVERRIDES)) {
  const h = bySlug().get(slug);
  if (!h) {
    warnings.push(`CATEGORY_OVERRIDES skipped: ${slug} missing`);
    continue;
  }
  h.category = category;
}

for (const h of hubs) {
  if (MIN_AGE_21.has(h.slug)) h.minAge = 21;
}

for (const [slug, extra] of Object.entries(ALIASES)) {
  const h = bySlug().get(slug);
  if (!h) throw new Error(`ALIASES key "${slug}" matches no hub slug`);
  h.aliases = Array.from(new Set([...h.aliases, ...extra]));
}

// Guards
const categorySlugs = new Set<string>();
for (const c of categories) {
  if (categorySlugs.has(c.slug)) throw new Error(`Duplicate category slug ${c.slug}`);
  categorySlugs.add(c.slug);
}
for (const h of hubs) {
  if (!categorySlugs.has(h.category))
    throw new Error(`Hub ${h.slug} references unknown category ${h.category}`);
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(h.slug)) throw new Error(`Bad slug ${h.slug}`);
}

const lines: string[] = [];
lines.push(
  "-- Generated by scripts/gen-hub-seed.mts. Do not edit by hand; edit the catalog and re-run.",
);
lines.push(`-- ${categories.length} categories, ${hubs.length} hubs.`);
lines.push("");
lines.push(
  "insert into public.hub_categories (slug, name, color_key, sort_order, is_sensitive, scope, min_age) values",
);
lines.push(
  categories
    .map(
      (c) =>
        `  (${sqlString(c.slug)}, ${sqlString(c.name)}, ${sqlString(c.colorKey)}, ${c.sort}, ${c.isSensitive ? "true" : "false"}, ${sqlString(c.scope ?? "general")}, ${c.minAge ?? 18})`,
    )
    .join(",\n"),
);
lines.push(
  "on conflict (slug) do update set name = excluded.name, color_key = excluded.color_key, sort_order = excluded.sort_order, is_sensitive = excluded.is_sensitive, scope = excluded.scope, min_age = excluded.min_age;",
);
lines.push("");
lines.push(
  "insert into public.hubs (slug, name, category_slug, emoji, aliases, scope, min_age) values",
);
lines.push(
  hubs
    .map(
      (h) =>
        `  (${sqlString(h.slug)}, ${sqlString(h.name)}, ${sqlString(h.category)}, ${sqlString(h.emoji)}, ${sqlTextArray(h.aliases)}, ${sqlString(h.scope)}, ${h.minAge})`,
    )
    .join(",\n"),
);
lines.push(
  "on conflict (slug) do update set name = excluded.name, category_slug = excluded.category_slug, emoji = excluded.emoji, aliases = excluded.aliases, scope = excluded.scope, min_age = excluded.min_age;",
);
lines.push("");

mkdirSync("supabase/seed", { recursive: true });
writeFileSync("supabase/seed/hubs.sql", lines.join("\n"), "utf8");
for (const w of warnings) console.warn("warning:", w);
console.log(`wrote supabase/seed/hubs.sql: ${categories.length} categories, ${hubs.length} hubs`);
