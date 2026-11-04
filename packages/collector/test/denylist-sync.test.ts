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
