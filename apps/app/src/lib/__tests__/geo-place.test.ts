import { describe, expect, it } from "vitest";

import { isNamedPlace } from "../geo-place";

describe("isNamedPlace", () => {
  it("treats amenities and named buildings as places", () => {
    expect(isNamedPlace({ result_type: "amenity", name: "Piedmont Park" })).toBe(true);
    expect(isNamedPlace({ result_type: "amenity" })).toBe(true);
    expect(
      isNamedPlace({
        result_type: "building",
        name: "Classroom South",
        address_line1: "Classroom South",
      }),
    ).toBe(true);
  });

  it("treats street addresses as private by default", () => {
    expect(
      isNamedPlace({
        result_type: "building",
        name: "123 Elm St NE",
        address_line1: "123 Elm St NE",
        housenumber: "123",
      }),
    ).toBe(false);
    expect(isNamedPlace({ result_type: "building", address_line1: "123 Elm St NE" })).toBe(false);
    expect(isNamedPlace({ name: "742 Evergreen Terrace" })).toBe(false);
    expect(isNamedPlace({ result_type: "street", name: "Peachtree Street" })).toBe(false);
    expect(isNamedPlace({ result_type: "postcode", name: "30303" })).toBe(false);
  });
});
