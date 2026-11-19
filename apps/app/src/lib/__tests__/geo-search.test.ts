import { beforeEach, describe, expect, it, vi } from "vitest";

const invoke = vi.fn();
vi.mock("../supabase", () => ({ supabase: { functions: { invoke } } }));

const { geoSearch, geoSearchAvailable, parseGeoSearchAnswer, resetGeoSearchAvailability } =
  await import("../geo-search");
const { geoapifyAutocomplete } = await import("../venues");
const { geoapifyCitySearch } = await import("../location");

beforeEach(() => {
  invoke.mockReset();
  resetGeoSearchAvailability();
});

describe("geo-search", () => {
  it("reads the answer defensively", () => {
    expect(parseGeoSearchAnswer(null)).toEqual({ enabled: true, results: [] });
    expect(parseGeoSearchAnswer({ enabled: false, results: [] })).toEqual({
      enabled: false,
      results: [],
    });
    expect(parseGeoSearchAnswer({ enabled: true, results: [1, { place_id: "a" }] })).toEqual({
      enabled: true,
      results: [{ place_id: "a" }],
    });
  });

  it("calls the Edge Function, never Geoapify, and sends the bias", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    invoke.mockResolvedValue({
      data: {
        enabled: true,
        results: [
          {
            formatted: "Piedmont Park, Atlanta",
            name: "Piedmont Park",
            address_line1: "Piedmont Park",
            result_type: "amenity",
            city: "Atlanta",
            state_code: "GA",
            country_code: "us",
            lat: 33.78,
            lon: -84.37,
            place_id: "p1",
          },
          { formatted: "no point" },
        ],
      },
      error: null,
    });
    const out = await geoapifyAutocomplete("piedmont", { lat: 33.7, lng: -84.4 });
    expect(invoke).toHaveBeenCalledWith("geo-search", {
      body: { kind: "address", text: "piedmont", bias: { lat: 33.7, lng: -84.4 } },
    });
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(out).toHaveLength(1);
    expect(out[0]).toMatchObject({ country: "US", lat: 33.78, lng: -84.37, namedPlace: true });
    fetchSpy.mockRestore();
  });

  it("stops asking once the server has no key", async () => {
    invoke.mockResolvedValue({ data: { enabled: false, results: [] }, error: null });
    expect(await geoapifyCitySearch("Lisbon")).toEqual({ enabled: false, places: [] });
    expect(geoSearchAvailable()).toBe(false);
    expect(await geoSearch("city", "Porto")).toEqual({ enabled: false, results: [] });
    expect(invoke).toHaveBeenCalledTimes(1);
  });

  it("turns a cap into a readable error", async () => {
    invoke.mockResolvedValue({ data: null, error: { context: { status: 429 } } });
    await expect(geoSearch("city", "Lisbon")).rejects.toThrow("Too many searches");
    expect(geoSearchAvailable()).toBe(true);
  });
});
