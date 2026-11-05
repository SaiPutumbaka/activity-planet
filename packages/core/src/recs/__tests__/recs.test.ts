import { describe, expect, it } from "vitest";

import {
  goingLabel,
  landingPoint,
  MAX_CHIPS,
  namesGeorgiaState,
  parseRecPrefs,
  parseReasons,
  parseRows,
  parseWeekCards,
  priceLabel,
  reasonLabel,
  recEventSchema,
  recPersonSchema,
  roundLandingCoordinate,
  splitReasons,
  whyLines,
  type Reason,
} from "../index";

describe("parseReasons", () => {
  it("keeps known reasons and drops unknown or malformed ones", () => {
    const out = parseReasons([
      { code: "near", band: "1-5 mi" },
      { code: "made_up" },
      { code: "people_met_going", n: 0 },
      { code: "like_hub" },
      { code: "free", extra: "dropped" },
      "nonsense",
    ]);
    expect(out).toEqual([{ code: "near", band: "1-5 mi" }, { code: "free" }]);
  });

  it("gives an empty list for anything that is not an array", () => {
    expect(parseReasons(null)).toEqual([]);
    expect(parseReasons({ code: "free" })).toEqual([]);
  });

  it("accepts a numeric rating average sent as a string", () => {
    expect(parseReasons([{ code: "rated", avg: "4.8", n: 12 }])).toEqual([
      { code: "rated", avg: 4.8, n: 12 },
    ]);
  });
});

describe("reasonLabel", () => {
  const cases: [Reason, string][] = [
    [{ code: "people_met_going", n: 2 }, "2 people you've met are going"],
    [{ code: "people_met_going", n: 1 }, "1 person you've met is going"],
    [{ code: "like_hub", hub_name: "Climbing" }, "Like Climbing"],
    [{ code: "like_plan", title: "Tuesday trivia" }, "Like Tuesday trivia"],
    [{ code: "in_your_hub", hub_name: "Running" }, "In Running"],
    [{ code: "same_hub", hub_name: "Pickleball" }, "Also Pickleball"],
    [{ code: "when", when: "tonight" }, "Tonight"],
    [{ code: "when", when: "this_weekend" }, "This weekend"],
    [{ code: "near", band: "1-5 mi" }, "1-5 mi away"],
    [{ code: "near", band: "<1 mi" }, "Under 1 mi away"],
    [{ code: "near", band: "online" }, "Online"],
    [{ code: "free" }, "Free"],
    [{ code: "popular" }, "Filling up"],
    [{ code: "from_source", source_name: "City Parks" }, "From City Parks"],
    [{ code: "teaches_your_hub", hub_name: "Tennis" }, "Coaches Tennis"],
    [{ code: "rated", avg: 4.8, n: 12 }, "4.8 from 12 reviews"],
    [{ code: "went_to_same", title: "Sunday run club" }, "You both went to Sunday run club"],
    [{ code: "same_chapter", chapter_name: "Midtown Runners" }, "Both in Midtown Runners"],
    [{ code: "going_to_same", title: "Saturday hike" }, "Also going to Saturday hike"],
    [{ code: "nearby_plans", n: 6 }, "6 plans near you this month"],
    [{ code: "nearby_plans", n: 1 }, "1 plan near you this month"],
    [{ code: "coming_up" }, "Coming up near you"],
  ];
  it.each(cases)("%o", (r, label) => {
    expect(reasonLabel(r)).toBe(label);
  });
});

describe("splitReasons", () => {
  it("keeps two chips at most and the attribution apart", () => {
    const { chips, attribution } = splitReasons([
      { code: "when", when: "today" },
      { code: "free" },
      { code: "popular" },
      { code: "from_source", source_name: "City Parks" },
    ]);
    expect(chips).toHaveLength(MAX_CHIPS);
    expect(chips.map((c) => c.code)).toEqual(["when", "free"]);
    expect(attribution?.source_name).toBe("City Parks");
  });

  it("drops a chip whose words repeat another", () => {
    const { chips } = splitReasons([{ code: "online" }, { code: "near", band: "online" }]);
    expect(chips).toEqual([{ code: "online" }]);
  });

  it("whyLines says a band in words", () => {
    expect(whyLines([{ code: "near", band: "<1 mi" }])).toEqual(["It's under 1 mi away."]);
  });

  it("whyLines always says something", () => {
    expect(whyLines([])).toEqual(["It's coming up near you."]);
    expect(whyLines([{ code: "free" }, { code: "from_source", source_name: "X" }])).toEqual([
      "It's free.",
      "It's listed from X.",
    ]);
  });
});

describe("rows", () => {
  it("parses event rows and skips broken ones", () => {
    const rows = parseRows(recEventSchema, [
      {
        id: "e1",
        kind: "member",
        title: "Run",
        starts_at: "2026-11-06T00:00:00Z",
        ends_at: "2026-11-06T01:00:00Z",
        timezone: "Europe/London",
        is_free: true,
        going_count: 3,
        distance_band: "1-5 mi",
        is_imported: false,
        reasons: [{ code: "free" }],
        rank: 1,
        description: "dropped",
      },
      { id: "", title: "bad" },
    ]);
    expect(rows).toHaveLength(1);
    expect(rows[0]).not.toHaveProperty("description");
    expect(rows[0]?.reasons).toEqual([{ code: "free" }]);
    expect(rows[0]?.hub_name).toBeNull();
  });

  it("people rows carry no extra fields", () => {
    const [p] = parseRows(recPersonSchema, [
      { user_id: "u", first_name: "Ana", sim: 0.9, hubs: ["x"], reasons: [], rank: 1 },
    ]);
    expect(p).toEqual({
      user_id: "u",
      handle: null,
      first_name: "Ana",
      avatar_url: null,
      reasons: [],
      rank: 1,
    });
  });

  it("prefs default to on", () => {
    expect(parseRecPrefs(null)).toEqual({ personalize: true, people_suggestions: true });
    expect(parseRecPrefs({ personalize: false })).toEqual({
      personalize: false,
      people_suggestions: true,
    });
  });
});

describe("landing", () => {
  it("rounds to 0.1 degree", () => {
    expect(roundLandingCoordinate(33.749)).toBe(33.7);
    expect(roundLandingCoordinate(-84.388)).toBe(-84.4);
    expect(Object.is(roundLandingCoordinate(-0.01), 0)).toBe(true);
  });

  it("validates a point", () => {
    expect(landingPoint("51.5074", "-0.1278")).toEqual({ lat: 51.5, lng: -0.1 });
    expect(landingPoint("91", "0")).toBeNull();
    expect(landingPoint("x", "0")).toBeNull();
    expect(landingPoint(null, "0")).toBeNull();
    expect(landingPoint("", "")).toBeNull();
  });

  it("parses week cards", () => {
    const cards = parseWeekCards([
      {
        id: "e1",
        title: "Pickup",
        hub: { name: "Soccer", emoji: "⚽", slug: "soccer" },
        starts_at: "2026-11-07T15:00:00Z",
        timezone: "America/Chicago",
        is_free: true,
        price_text: null,
        going_bucket: "10+",
        distance_band: "1-5 mi",
        is_imported: false,
        source_name: null,
        host_id: "dropped",
      },
      { title: "no id" },
    ]);
    expect(cards).toHaveLength(1);
    expect(cards[0]).not.toHaveProperty("host_id");
    expect(goingLabel(cards[0]!.going_bucket)).toBe("10+ going");
    expect(priceLabel(cards[0]!)).toBe("Free");
    expect(priceLabel({ is_free: false, price_text: " $5 " })).toBe("$5");
  });

  it("names Georgia State only when the source does", () => {
    expect(namesGeorgiaState("Georgia State University Events")).toBe(true);
    expect(namesGeorgiaState("GSU Localist")).toBe(true);
    expect(namesGeorgiaState("City Parks")).toBe(false);
    expect(namesGeorgiaState(null)).toBe(false);
  });
});
