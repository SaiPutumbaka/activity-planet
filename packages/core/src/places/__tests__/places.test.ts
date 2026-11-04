import { describe, expect, it } from "vitest";

import {
  MAX_PLACE_LABEL,
  STARTER_CITIES,
  feedOriginLabel,
  formatPlaceLabel,
  geoapifyCityToPlace,
  normalizePlaceText,
  parseGeoPoint,
  searchStarterCities,
  shortPlaceLabel,
  starterCityLabel,
} from "../index";

describe("STARTER_CITIES", () => {
  it("has about forty cities with unique ids and names", () => {
    expect(STARTER_CITIES.length).toBeGreaterThanOrEqual(38);
    expect(STARTER_CITIES.length).toBeLessThanOrEqual(60);
    expect(new Set(STARTER_CITIES.map((c) => c.id)).size).toBe(STARTER_CITIES.length);
    expect(new Set(STARTER_CITIES.map((c) => starterCityLabel(c))).size).toBe(
      STARTER_CITIES.length,
    );
  });

  it("gives every city valid coordinates at two decimals and a country", () => {
    for (const c of STARTER_CITIES) {
      expect(c.id).toMatch(/^[a-z0-9-]+$/);
      expect(c.name.trim()).toBe(c.name);
      expect(c.country.length).toBeGreaterThan(1);
      expect(c.countryCode).toMatch(/^[A-Z]{2}$/);
      expect(c.lat).toBeGreaterThanOrEqual(-90);
      expect(c.lat).toBeLessThanOrEqual(90);
      expect(c.lng).toBeGreaterThanOrEqual(-180);
      expect(c.lng).toBeLessThanOrEqual(180);
      expect(Math.round(c.lat * 100) / 100).toBe(c.lat);
      expect(Math.round(c.lng * 100) / 100).toBe(c.lng);
      expect(starterCityLabel(c).length).toBeLessThanOrEqual(MAX_PLACE_LABEL);
    }
  });

  it("spans every inhabited continent and leaves Atlanta to the areas table", () => {
    const southern = STARTER_CITIES.filter((c) => c.lat < 0).length;
    const eastern = STARTER_CITIES.filter((c) => c.lng > 60).length;
    const western = STARTER_CITIES.filter((c) => c.lng < -30).length;
    expect(southern).toBeGreaterThanOrEqual(5);
    expect(eastern).toBeGreaterThanOrEqual(8);
    expect(western).toBeGreaterThanOrEqual(10);
    expect(new Set(STARTER_CITIES.map((c) => c.countryCode)).size).toBeGreaterThanOrEqual(25);
    expect(STARTER_CITIES.some((c) => normalizePlaceText(c.name) === "atlanta")).toBe(false);
  });
});

describe("formatPlaceLabel", () => {
  it("joins name, region and country", () => {
    expect(formatPlaceLabel({ name: "Austin", region: "Texas", country: "United States" })).toBe(
      "Austin, Texas, United States",
    );
    expect(formatPlaceLabel({ name: "London", country: "United Kingdom" })).toBe(
      "London, United Kingdom",
    );
  });

  it("drops blanks, repeats and extra whitespace", () => {
    expect(formatPlaceLabel({ name: "Singapore", region: "", country: "Singapore" })).toBe(
      "Singapore",
    );
    expect(formatPlaceLabel({ name: "  São   Paulo ", region: null, country: "Brazil" })).toBe(
      "São Paulo, Brazil",
    );
    expect(formatPlaceLabel({ name: "Hong Kong", country: "hong kong" })).toBe("Hong Kong");
    expect(formatPlaceLabel({})).toBe("");
  });

  it("caps the label at the database limit", () => {
    const long = formatPlaceLabel({ name: "x".repeat(200) });
    expect(long.length).toBe(MAX_PLACE_LABEL);
  });
});

describe("shortPlaceLabel and feedOriginLabel", () => {
  it("keeps the first part of a label", () => {
    expect(shortPlaceLabel("Lisbon, Portugal")).toBe("Lisbon");
    expect(shortPlaceLabel("Midtown")).toBe("Midtown");
    expect(shortPlaceLabel("  ")).toBeNull();
    expect(shortPlaceLabel(null)).toBeNull();
  });

  it("says near you for a device point or an unlabeled home", () => {
    expect(feedOriginLabel({ usingDevice: true, homeLabel: "Tokyo, Japan" })).toBe("Near you");
    expect(feedOriginLabel({ usingDevice: false, homeLabel: null })).toBe("Near you");
    expect(feedOriginLabel({ usingDevice: false, homeLabel: "Tokyo, Japan" })).toBe("Tokyo");
  });
});

describe("searchStarterCities", () => {
  it("matches names and aliases without case or accents", () => {
    expect(searchStarterCities("lon").map((c) => c.id)).toEqual(["london"]);
    expect(searchStarterCities("sao")[0]?.id).toBe("sao-paulo");
    expect(searchStarterCities("BOGOTA")[0]?.id).toBe("bogota");
    expect(searchStarterCities("bangalore")[0]?.id).toBe("bengaluru");
    expect(searchStarterCities("nyc")[0]?.id).toBe("new-york");
  });

  it("puts exact and prefix matches first and respects the limit", () => {
    const m = searchStarterCities("m");
    expect(m.length).toBeLessThanOrEqual(8);
    expect(
      m.every((c) => normalizePlaceText([c.name, ...(c.aliases ?? [])].join(" ")).includes("m")),
    ).toBe(true);
    expect(searchStarterCities("rio")[0]?.id).toBe("rio-de-janeiro");
    expect(searchStarterCities("", undefined, 8)).toEqual([]);
    expect(searchStarterCities("zzzz")).toEqual([]);
  });
});

describe("geoapifyCityToPlace", () => {
  it("labels a city with its state and country", () => {
    expect(
      geoapifyCityToPlace({
        result_type: "city",
        name: "Austin",
        city: "Austin",
        state: "Texas",
        country: "United States",
        lat: 30.2711,
        lon: -97.7437,
        place_id: "p1",
      }),
    ).toEqual({
      id: "p1",
      name: "Austin",
      label: "Austin, Texas, United States",
      lat: 30.2711,
      lng: -97.7437,
    });
  });

  it("keeps a neighborhood's city in the label", () => {
    expect(
      geoapifyCityToPlace({
        result_type: "suburb",
        suburb: "Shoreditch",
        city: "London",
        state: "England",
        country: "United Kingdom",
        lat: 51.52,
        lon: -0.08,
        place_id: "p2",
      })?.label,
    ).toBe("Shoreditch, London, United Kingdom");
  });

  it("skips streets, venues and results without coordinates", () => {
    expect(
      geoapifyCityToPlace({
        result_type: "street",
        name: "Main St",
        lat: 1,
        lon: 1,
        place_id: "x",
      }),
    ).toBeNull();
    expect(
      geoapifyCityToPlace({
        result_type: "amenity",
        name: "A Café",
        lat: 1,
        lon: 1,
        place_id: "x",
      }),
    ).toBeNull();
    expect(geoapifyCityToPlace({ result_type: "city", name: "Nowhere", place_id: "x" })).toBeNull();
  });
});

describe("parseGeoPoint", () => {
  // SELECT ST_SetSRID(ST_MakePoint(-0.13, 51.51), 4326)::geography  (PostgREST's text output)
  const london = "0101000020E6100000A4703D0AD7A3C0BFE17A14AE47C14940";

  it("reads PostgREST's hex EWKB", () => {
    const p = parseGeoPoint(london);
    expect(p?.lat).toBeCloseTo(51.51, 6);
    expect(p?.lng).toBeCloseTo(-0.13, 6);
  });

  it("reads GeoJSON", () => {
    expect(parseGeoPoint({ type: "Point", coordinates: [139.69, 35.68] })).toEqual({
      lat: 35.68,
      lng: 139.69,
    });
  });

  it("returns null for anything else", () => {
    expect(parseGeoPoint(null)).toBeNull();
    expect(parseGeoPoint("")).toBeNull();
    expect(parseGeoPoint("not hex")).toBeNull();
    // A LineString header.
    expect(parseGeoPoint("0102000020E6100000A4703D0AD7A3C0BFE17A14AE47C14940")).toBeNull();
    expect(parseGeoPoint({ type: "Point", coordinates: [0, 200] })).toBeNull();
  });
});
