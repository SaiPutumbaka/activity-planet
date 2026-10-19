/**
 * Generate supabase/seed/hubs.sql from packages/core/src/catalog/hub-catalog.ts plus the
 * campus-life categories, so the hubs table is seeded from one source of truth.
 *
 * Run:  node --experimental-strip-types scripts/gen-hub-seed.mts
 */
import { writeFileSync, mkdirSync } from "node:fs";
import { HUB_CATALOG } from "../packages/core/src/catalog/hub-catalog.ts";

type Category = { slug: string; name: string; colorKey: string; sort: number };

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
      slug: "careers-networking",
      name: "Careers & Networking",
      colorKey: "learning",
      sort: 80,
    },
    hubs: [
      { name: "Career Events", emoji: "💼", aliases: ["career fair", "recruiting", "employer"] },
      { name: "Networking Nights", emoji: "🤝" },
      { name: "Internships & Jobs", emoji: "📄", aliases: ["handshake", "hiring"] },
      { name: "Entrepreneurship", emoji: "🚀", aliases: ["startup", "founders", "pitch"] },
      { name: "Resume & Interview Prep", emoji: "📝" },
    ],
  },
  {
    category: {
      slug: "academics-study",
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
      slug: "culture-identity",
      name: "Culture & Identity",
      colorKey: "social",
      sort: 82,
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
      slug: "faith-spirituality",
      name: "Faith & Spirituality",
      colorKey: "social",
      sort: 83,
    },
    hubs: [
      { name: "Christian Fellowship", emoji: "✝️" },
      { name: "Muslim Student Life", emoji: "☪️" },
      { name: "Jewish Student Life", emoji: "✡️" },
      { name: "Hindu & Sikh Community", emoji: "🕉️" },
      { name: "Buddhist & Mindfulness", emoji: "☸️" },
      { name: "Interfaith Dialogue", emoji: "🕊️" },
    ],
  },
  {
    category: { slug: "service-causes", name: "Service & Causes", colorKey: "outdoors", sort: 84 },
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
      slug: "wellness-support",
      name: "Wellness & Support",
      colorKey: "wellness",
      sort: 85,
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
    category: { slug: "campus-life", name: "Campus Life & Free Food", colorKey: "food", sort: 86 },
    hubs: [
      { name: "Free Food", emoji: "🍕", aliases: ["pizza", "snacks", "refreshments"] },
      {
        name: "Campus Traditions & Spirit",
        emoji: "🐾",
        aliases: ["homecoming", "pep rally", "spirit"],
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
    category: { slug: "nightlife-21", name: "Nightlife & 21+", colorKey: "nightlife", sort: 90 },
    hubs: [
      { name: "Bar Trivia", emoji: "🍻", aliases: ["trivia night", "pub quiz"] },
      { name: "Brewery Runs & Tours", emoji: "🍺" },
      { name: "Wine Tasting", emoji: "🍷" },
      { name: "Cocktail Nights", emoji: "🍸" },
      { name: "Clubs & DJ Nights", emoji: "🪩", aliases: ["club", "dj", "nightclub"] },
      { name: "Comedy Clubs", emoji: "🎙️" },
      { name: "Live Music Venues", emoji: "🎸", aliases: ["concert", "gig", "show"] },
    ],
  },
];

function slugify(input: string): string {
  return input
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/&/g, " and ")
    .replace(/[^a-zA-Z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase();
}

function sqlString(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

function sqlTextArray(values: string[]): string {
  if (values.length === 0) return "'{}'::text[]";
  return `array[${values.map(sqlString).join(", ")}]`;
}

const categories: Category[] = [];
const hubs: Array<{
  slug: string;
  name: string;
  category: string;
  emoji: string;
  aliases: string[];
}> = [];
const seenSlugs = new Map<string, string>();

for (const group of HUB_CATALOG) {
  const meta = CATEGORY_META[group.category];
  if (!meta) throw new Error(`No category meta for "${group.category}"`);
  const slug = slugify(group.category);
  categories.push({ slug, name: group.category, colorKey: meta.colorKey, sort: meta.sort });
  for (const hub of group.hubs) {
    const hubSlug = slugify(hub.name);
    const prior = seenSlugs.get(hubSlug);
    if (prior)
      throw new Error(`Slug collision: "${hub.name}" and "${prior}" both map to ${hubSlug}`);
    seenSlugs.set(hubSlug, hub.name);
    hubs.push({ slug: hubSlug, name: hub.name, category: slug, emoji: hub.emoji, aliases: [] });
  }
}

for (const group of CAMPUS_LIFE) {
  categories.push(group.category);
  for (const hub of group.hubs) {
    const hubSlug = slugify(hub.name);
    const existing = hubs.find((h) => h.slug === hubSlug);
    if (existing) {
      // Already in the hobby catalog (e.g. "Volunteering"): keep the catalog entry, merge aliases.
      existing.aliases = Array.from(new Set([...existing.aliases, ...(hub.aliases ?? [])]));
      continue;
    }
    seenSlugs.set(hubSlug, hub.name);
    hubs.push({
      slug: hubSlug,
      name: hub.name,
      category: group.category.slug,
      emoji: hub.emoji,
      aliases: hub.aliases ?? [],
    });
  }
}

// Synonyms that the 2026-07 catalog carried as separate entries; keep both hubs but let search
// land on the canonical one via aliases.
const ALIASES: Record<string, string[]> = {
  "table-tennis": ["ping pong"],
  "ping-pong": ["table tennis"],
  pool: ["billiards", "8 ball", "nine ball"],
  "road-running": ["running", "jogging"],
  running: ["jogging", "run club"],
  "video-gaming-and-esports": ["gaming"],
  "pc-gaming": ["gaming"],
  basketball: ["hoops", "pickup basketball", "pickup"],
  soccer: ["football (soccer)", "futbol", "pickup soccer"],
  "american-football": ["football"],
  volleyball: ["indoor volleyball", "pickup volleyball"],
  anime: ["manga", "anime club", "anime night"],
  chess: ["chess club"],
  "board-games": ["tabletop", "board game night"],
};
for (const hub of hubs) {
  const extra = ALIASES[hub.slug];
  if (extra) hub.aliases = Array.from(new Set([...hub.aliases, ...extra]));
}

const lines: string[] = [];
lines.push(
  "-- Generated by scripts/gen-hub-seed.mts. Do not edit by hand; edit the catalog and re-run.",
);
lines.push(`-- ${categories.length} categories, ${hubs.length} hubs.`);
lines.push("");
lines.push("insert into public.hub_categories (slug, name, color_key, sort_order) values");
lines.push(
  categories
    .map(
      (c) => `  (${sqlString(c.slug)}, ${sqlString(c.name)}, ${sqlString(c.colorKey)}, ${c.sort})`,
    )
    .join(",\n"),
);
lines.push(
  "on conflict (slug) do update set name = excluded.name, color_key = excluded.color_key, sort_order = excluded.sort_order;",
);
lines.push("");
lines.push("insert into public.hubs (slug, name, category_slug, emoji, aliases) values");
lines.push(
  hubs
    .map(
      (h) =>
        `  (${sqlString(h.slug)}, ${sqlString(h.name)}, ${sqlString(h.category)}, ${sqlString(h.emoji)}, ${sqlTextArray(h.aliases)})`,
    )
    .join(",\n"),
);
lines.push(
  "on conflict (slug) do update set name = excluded.name, category_slug = excluded.category_slug, emoji = excluded.emoji, aliases = excluded.aliases;",
);
lines.push("");

mkdirSync("supabase/seed", { recursive: true });
writeFileSync("supabase/seed/hubs.sql", lines.join("\n"), "utf8");
console.log(`wrote supabase/seed/hubs.sql: ${categories.length} categories, ${hubs.length} hubs`);
