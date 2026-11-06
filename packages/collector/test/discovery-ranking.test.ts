// The cheap-score ranking that decides which candidates the probe reads (design 6.3), checked on
// the Atlanta gate's own candidate list. Run 42131965214 failed the gate 4 of 9 because a +25
// Wikidata bonus pushed a city site 26 places name (rank 95 to 176) and a theatre linking its
// events page (60 to 175) past the 150-host cap, unprobed.
import { describe, expect, it } from "vitest";
import {
  type Candidate,
  cheapScore,
  isGovernmentHost,
  KIND_PRIOR,
  mergeCandidates,
  osmCandidates,
  siteKind,
  type TileRow,
  WIKIDATA_BONUS,
} from "../src/discovery/candidates.ts";
import { loadDiscoveryConfig } from "../src/discovery/config.ts";
import { Denylist } from "../src/policy/denylist.ts";
import { ATL, fixture } from "./helpers.ts";

const denylist = Denylist.load();
const cfg = loadDiscoveryConfig();
const CAP = cfg.caps.probeHostsPerRegionPerDay;

const KINDS: Record<string, string> = {
  art: "arts_venue",
  sch: "school",
  com: "community",
  lib: "library",
  att: "attraction",
  mak: "maker",
  dan: "dance",
  cin: "cinema",
  spo: "sports_centre",
  his: "historic",
  nat: "nature",
  par: "park",
  mar: "market",
  bar: "bar",
  bre: "brewery",
};

/** The fixture as tile rows (one per place) and Wikidata-only venues. */
function atlantaList(): { rows: TileRow[]; around: Candidate[] } {
  const rows: TileRow[] = [];
  const around: Candidate[] = [];
  let q = 1;
  for (const line of fixture("discovery/atl-gate-candidates.txt").split("\n")) {
    if (!line.trim() || line.startsWith("#")) continue;
    const [origin, host, kinds, places, wd, events] = line.trim().split(/\s+/);
    if (origin === "wikidata") {
      around.push({
        url: `https://${host}/`,
        host: host!,
        origin: "wikidata",
        place_kind: KINDS[kinds!],
        wikidata_id: `Q${q++}`,
        places: 1,
        score: 0,
      });
      continue;
    }
    const ks = kinds!.split(",").map((k) => KINDS[k]!);
    for (let i = 0; i < Number(places); i++) {
      const site = i === 0 && events ? `https://${host}/events/` : `https://${host}/`;
      const tags = i === 0 && wd === "1" ? { wikidata: `Q${q++}` } : null;
      rows.push([
        `n${rows.length + 1}`,
        ATL.lng,
        ATL.lat,
        ks[Math.min(i, ks.length - 1)]!,
        host!,
        [],
        null,
        null,
        null,
        site,
        tags,
      ]);
    }
  }
  return { rows, around };
}

function ranked(): Candidate[] {
  const { rows, around } = atlantaList();
  const osm = osmCandidates(rows, ATL, { denylist });
  return mergeCandidates(osm.candidates, new Map(), osm.wikidataIds, around, 500);
}

describe("candidate ranking", () => {
  it("keeps the gate's seeds that have candidates inside the probe cap on the Atlanta list", () => {
    const list = ranked();
    expect(list.length).toBeGreaterThan(CAP);
    // The fixture leaves out the 5 to 9 hosts it cannot rebuild offline: keep 10 places spare.
    const room = CAP - 10;
    const ranks: Record<string, number> = {};
    for (const site of [
      "kennesaw.edu",
      "atlantabg.org",
      "mariettaga.gov",
      "piedmontpark.org",
      "atlantahistorycenter.com",
      "alliancetheatre.org",
    ]) {
      ranks[site] = list.findIndex((c) => c.host === site) + 1;
      expect(ranks[site], site).toBeGreaterThan(0);
    }
    for (const [site, rank] of Object.entries(ranks)) expect(rank, site).toBeLessThanOrEqual(room);
    expect(list.find((c) => c.host === "mariettaga.gov")?.place_kind).toBe("community");
  });

  it("never lets a Wikidata tag alone outrank a host many places name or one linking its events", () => {
    const tagged = cheapScore({ place_kind: "arts_venue", wikidata_id: "Q1", places: 1 });
    expect(
      cheapScore({
        place_kind: "arts_venue",
        places: 1,
        extra_urls: ["https://x.org/content/shows-events"],
      }),
    ).toBeGreaterThanOrEqual(tagged);
    expect(cheapScore({ place_kind: "arts_venue", places: 6 })).toBeGreaterThanOrEqual(tagged);
    expect(WIKIDATA_BONUS).toBeLessThanOrEqual(10);
    // Nor lift a weaker kind's tagged venue over a stronger kind's untagged site with many places.
    expect(cheapScore({ place_kind: "park", wikidata_id: "Q1", places: 1 })).toBeLessThan(
      cheapScore({ place_kind: "community", places: 26 }),
    );
  });

  it("reaches a city site among many Wikidata-tagged single venues", () => {
    const around: Candidate[] = Array.from({ length: 200 }, (_, i) => ({
      url: `https://venue${i}.org/`,
      host: `venue${i}.org`,
      origin: "wikidata",
      place_kind: i % 2 ? "park" : "arts_venue",
      wikidata_id: `Q${i + 1}`,
      places: 1,
      score: 0,
    }));
    const rows: TileRow[] = Array.from({ length: 26 }, (_, i) => [
      `n${i}`,
      ATL.lng,
      ATL.lat,
      i === 0 ? "arts_venue" : "park",
      `Park ${i}`,
      [],
      null,
      null,
      null,
      `https://www.examplecityga.gov/parks/${i}`,
      null,
    ]);
    const osm = osmCandidates(rows, ATL, { denylist });
    const list = mergeCandidates(osm.candidates, new Map(), osm.wikidataIds, around, 500);
    const rank = list.findIndex((c) => c.host === "examplecityga.gov") + 1;
    expect(rank).toBeGreaterThan(0);
    expect(rank).toBeLessThanOrEqual(CAP);
  });
});

describe("government sites", () => {
  it("recognises a government's own website", () => {
    for (const h of [
      "mariettaga.gov",
      "www.brookhavenga.gov",
      "prca.cobbcountyga.gov",
      "alpharetta.ga.us",
      "co.dekalb.ga.us",
      "cityofmiltonga.us",
      "townofexample.org",
      "roswellgov.com",
      "camden.gov.uk",
    ])
      expect(isGovernmentHost(h), h).toBe(true);
    for (const h of [
      "hapeville.org",
      "alliancetheatre.org",
      "governorsclub.com",
      "gov.org.example",
    ])
      expect(isGovernmentHost(h), h).toBe(false);
  });

  it("scores a government site as a city site unless a place kind ranks higher", () => {
    expect(siteKind("mariettaga.gov", "arts_venue")).toBe("community");
    expect(siteKind("mariettaga.gov", "park")).toBe("community");
    expect(siteKind("mariettaga.gov", undefined)).toBe("community");
    expect(siteKind("countylibraryga.gov", "library")).toBe("library");
    expect(siteKind("alliancetheatre.org", "arts_venue")).toBe("arts_venue");
    expect(KIND_PRIOR.library!).toBeGreaterThan(KIND_PRIOR.community!);
  });
});
