import { readdirSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// The database has its own copy of the denylist (collector_denylist, migration 46), used by
// "Suggest a calendar" and the discovery lifecycle. Adding a site to data/denylist.json needs a
// migration that adds it there too; this test fails until it does.
const DATA = JSON.parse(
  readFileSync(new URL("../data/denylist.json", import.meta.url), "utf8"),
) as { domains: { domain: string }[]; anyTld: { name: string }[] };
const MIGRATIONS = new URL("../../../supabase/migrations/", import.meta.url);
const SQL = readdirSync(MIGRATIONS)
  .filter((f) => f.endsWith(".sql"))
  .map((f) => readFileSync(new URL(f, MIGRATIONS), "utf8"))
  .join("\n");

describe("denylist.json and collector_denylist agree", () => {
  it.each(DATA.domains.map((d) => d.domain))("domain %s is seeded in a migration", (domain) => {
    expect(SQL).toContain(`('${domain}', 'domain',`);
  });
  it.each(DATA.anyTld.map((d) => d.name))("any_tld %s is seeded in a migration", (name) => {
    expect(SQL).toContain(`('${name}', 'any_tld',`);
  });
});

// Collector completion 2.1: rows whose reason starts "owner request" are written by
// mod_listing_removal_resolve at run time and live only in the database; the collector reads them
// through GET /collector/denylist before each run. No migration may seed one, and every other
// seeded row must be in data/denylist.json.
describe("database-only denylist rows", () => {
  it("are never seeded by a migration", () => {
    expect(SQL).not.toMatch(/\('[a-z0-9.-]+', '(domain|any_tld)', 'owner request/);
  });
  it("every seeded collector_denylist row is in data/denylist.json", () => {
    const names = new Set([
      ...DATA.domains.map((d) => d.domain),
      ...DATA.anyTld.map((d) => d.name),
    ]);
    const block =
      /insert into public\.collector_denylist \(name, match, reason\) values([\s\S]*?)on conflict/g;
    for (const m of SQL.matchAll(block))
      for (const row of m[1]!.matchAll(/\('([a-z0-9.-]+)', '(domain|any_tld)',/g))
        expect(names.has(row[1]!), row[1]).toBe(true);
  });
});
