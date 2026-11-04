import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

import { placeFromVenueToken, placeVenueToken } from "../venues";

describe("place venue tokens", () => {
  const placeId = "0b6e1c1a-2f43-4a57-9d43-5d1f2b9d7e10";

  it("round-trips a map place with no venue yet", () => {
    expect(placeFromVenueToken(placeVenueToken(placeId))).toBe(placeId);
  });

  it("leaves real venue ids and empty values alone", () => {
    expect(placeFromVenueToken(placeId)).toBeNull();
    expect(placeFromVenueToken(null)).toBeNull();
    expect(placeFromVenueToken(undefined)).toBeNull();
    expect(placeFromVenueToken("")).toBeNull();
  });
});
