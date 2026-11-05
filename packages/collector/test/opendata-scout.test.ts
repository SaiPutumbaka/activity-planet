import { describe, expect, it } from "vitest";
import {
  formatRow,
  hubSearchUrl,
  parseHubSearch,
  parseSocrataCatalog,
  regionBox,
  scout,
  socrataAggregateUrl,
  socrataColumns,
} from "../src/opendata-scout.ts";
import { ATL, fixture } from "./helpers.ts";

describe("open-data scout", () => {
  it("keeps event datasets from the Socrata catalogue with their columns", () => {
    const rows = parseSocrataCatalog(fixture("scout/socrata-catalog.json"));
    expect(rows.map((r) => r.id)).toEqual(["abcd-1234", "libr-0002"]);
    expect(socrataColumns(rows[0]!)).toEqual({ geo: "location", date: "start_date" });
    expect(socrataColumns(rows[1]!)).toEqual({ geo: null, date: "starts" });
  });

  it("asks only aggregates inside the region's box", () => {
    const box = regionBox(ATL);
    const u = new URL(
      socrataAggregateUrl(
        "https://data.example-city.gov/resource/abcd-1234.json",
        "location",
        "start_date",
        box,
      ),
    );
    expect(u.searchParams.get("$select")).toBe("count(*) as n, max(start_date) as latest");
    expect(u.searchParams.get("$where")).toBe(
      `within_box(location, ${box[3]}, ${box[0]}, ${box[1]}, ${box[2]})`,
    );
    expect(new URL(hubSearchUrl("event", box)).searchParams.get("bbox")).toBe(box.join(","));
  });

  it("keeps event layers from ArcGIS Hub with a FeatureServer endpoint", () => {
    expect(
      parseHubSearch(
        JSON.stringify({
          features: [
            {
              properties: {
                id: "1",
                title: "Events",
                url: "https://s.arcgis.com/a/rest/services/E/FeatureServer",
              },
            },
          ],
        }),
      )[0]?.endpoint,
    ).toBe("https://s.arcgis.com/a/rest/services/E/FeatureServer/0");
    const rows = parseHubSearch(fixture("scout/hub-search.json"));
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      portal: "arcgis",
      id: "9f8e7d",
      licence: "CC BY 4.0",
      updated: "2026-11-01",
    });
  });

  it("filters by the box and prints metadata and counts only, never row values", async () => {
    const asked: string[] = [];
    const fetcher = {
      get: async (url: string) => {
        asked.push(url);
        const u = new URL(url);
        let body = "{}";
        if (u.hostname.endsWith("socrata.com")) body = fixture("scout/socrata-catalog.json");
        else if (u.hostname === "hub.arcgis.com") body = fixture("scout/hub-search.json");
        // The portal answers the aggregate only; a row value would be "Secret Party" if anything asked for rows.
        else if (u.pathname.endsWith("abcd-1234.json"))
          body = JSON.stringify([{ n: "12", latest: "2026-12-01T00:00:00.000" }]);
        return {
          ok: true as const,
          url,
          status: 200,
          contentType: "application/json",
          xRobotsTag: null,
          body,
          notModified: false,
        };
      },
    };
    const { rows, counts } = await scout({
      region: ATL,
      fetcher,
      appToken: "TOKEN-SECRET",
      domains: ["data.far-away.gov"],
    });
    expect(counts.aggregates).toBe(1);
    expect(counts.hub_features).toBe(8);
    // libr-0002 has no point column: listed only because its portal was asked for.
    expect(rows.map((r) => r.id).sort()).toEqual(["9f8e7d", "abcd-1234", "libr-0002"]);
    expect(asked.some((u) => new URL(u).searchParams.get("domains") === "data.far-away.gov")).toBe(
      true,
    );
    expect(rows.find((r) => r.id === "abcd-1234")).toMatchObject({
      inBox: 12,
      latest: "2026-12-01",
    });
    for (const u of asked.filter((x) => x.includes("/resource/")))
      expect(new URL(u).searchParams.get("$select")).toMatch(/^count\(\*\)/);
    const out = rows.map(formatRow).join("\n");
    expect(out).not.toContain("Secret Party");
    expect(out).not.toContain("TOKEN-SECRET");
    expect(out).toContain("in_box=12");
  });

  it("leaves out a Socrata dataset with nothing inside the box", async () => {
    const fetcher = {
      get: async (url: string) => {
        const u = new URL(url);
        const body = u.hostname.endsWith("socrata.com")
          ? fixture("scout/socrata-catalog.json")
          : u.pathname.includes("/resource/")
            ? JSON.stringify([{ n: "0" }])
            : JSON.stringify({ features: [] });
        return {
          ok: true as const,
          url,
          status: 200,
          contentType: "application/json",
          xRobotsTag: null,
          body,
          notModified: false,
        };
      },
    };
    const { rows } = await scout({ region: ATL, fetcher });
    expect(rows).toEqual([]);
  });
});
