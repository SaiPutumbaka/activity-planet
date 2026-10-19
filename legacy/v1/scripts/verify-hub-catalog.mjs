// Guards against drift between the two hand-authored hub sources:
//   src/types/database.ts  — the flat HUBS array (drives the Hub type & Zod enum)
//   src/lib/hub-catalog.ts — the categorized catalog (drives the UI pickers)
// Run with: node scripts/verify-hub-catalog.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");

function extractHubsArray(source) {
  const match = source.match(/export const HUBS = \[([\s\S]*?)\] as const;/);
  if (!match) {
    throw new Error("Could not find `export const HUBS = [...] as const;` in database.ts");
  }
  return [...match[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}

function extractCatalogNames(source) {
  const match = source.match(/export const HUB_CATALOG[\s\S]*$/);
  if (!match) {
    throw new Error("Could not find `export const HUB_CATALOG` in hub-catalog.ts");
  }
  return [...match[0].matchAll(/name:\s*"([^"]+)"/g)].map((m) => m[1]);
}

function slugify(name) {
  return name
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function findDuplicates(items) {
  const seen = new Set();
  const dupes = new Set();
  for (const item of items) {
    if (seen.has(item)) dupes.add(item);
    seen.add(item);
  }
  return [...dupes];
}

const dbSource = readFileSync(join(root, "src/types/database.ts"), "utf8");
const catalogSource = readFileSync(join(root, "src/lib/hub-catalog.ts"), "utf8");

const hubs = extractHubsArray(dbSource);
const catalogNames = extractCatalogNames(catalogSource);

const hubSet = new Set(hubs);
const catalogSet = new Set(catalogNames);

const errors = [];

const dupHubs = findDuplicates(hubs);
if (dupHubs.length > 0) errors.push(`Duplicate entries in HUBS: ${dupHubs.join(", ")}`);

const dupCatalog = findDuplicates(catalogNames);
if (dupCatalog.length > 0) errors.push(`Duplicate entries in HUB_CATALOG: ${dupCatalog.join(", ")}`);

const missingFromCatalog = hubs.filter((h) => !catalogSet.has(h));
if (missingFromCatalog.length > 0) {
  errors.push(`In HUBS but missing from HUB_CATALOG: ${missingFromCatalog.join(", ")}`);
}

const extraInCatalog = catalogNames.filter((h) => !hubSet.has(h));
if (extraInCatalog.length > 0) {
  errors.push(`In HUB_CATALOG but missing from HUBS: ${extraInCatalog.join(", ")}`);
}

const slugCounts = new Map();
for (const hub of hubs) {
  const slug = slugify(hub);
  slugCounts.set(slug, [...(slugCounts.get(slug) ?? []), hub]);
}
for (const [slug, names] of slugCounts) {
  if (names.length > 1) {
    errors.push(`Slug collision "${slug}": ${names.join(", ")}`);
  }
}

if (errors.length > 0) {
  console.error(`FAILED — ${errors.length} issue(s):\n`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}

console.log(`OK — ${hubs.length} hubs, all present in both files, no duplicates, no slug collisions.`);
