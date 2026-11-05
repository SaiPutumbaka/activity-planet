import { describe, expect, it } from "vitest";

import { bandLabel } from "../../coaching";
import { reasonLabel, whyLines } from "../../recs";
import { bandText, distanceBandLabel, distanceUnitForLocale } from "..";

describe("distanceUnitForLocale", () => {
  it("gives miles where people use them and kilometres elsewhere", () => {
    expect(distanceUnitForLocale("en-US")).toBe("mi");
    expect(distanceUnitForLocale("en-GB")).toBe("mi");
    expect(distanceUnitForLocale("de-DE")).toBe("km");
    expect(distanceUnitForLocale("en-AU")).toBe("km");
    expect(distanceUnitForLocale("fr")).toBe("km");
    expect(distanceUnitForLocale("en")).toBe("mi");
    expect(distanceUnitForLocale(undefined)).toBe("mi");
    expect(distanceUnitForLocale("not a locale")).toBe("mi");
  });
});

describe("bands in kilometres", () => {
  it("words every band in either unit", () => {
    expect(bandText("<1 mi", "km")).toBe("Under 2 km");
    expect(bandText("1-5 mi", "km")).toBe("2 to 8 km");
    expect(bandText("25+ mi", "km")).toBe("40+ km");
    expect(bandText("1-5 mi")).toBe("1 to 5 mi");
    expect(bandText("online", "km")).toBe("online");
    expect(distanceBandLabel("5-10 mi", "km")).toBe("8 to 16 km");
    expect(distanceBandLabel("approximate", "km")).toBe("Approximate area");
    expect(distanceBandLabel("bogus", "km")).toBeNull();
  });

  it("reason chips, why lines and coach rows follow the unit", () => {
    expect(reasonLabel({ code: "near", band: "1-5 mi" }, "km")).toBe("2-8 km away");
    expect(reasonLabel({ code: "near", band: "<1 mi" }, "km")).toBe("Under 2 km away");
    expect(reasonLabel({ code: "near", band: "1-5 mi" })).toBe("1-5 mi away");
    expect(whyLines([{ code: "near", band: "<1 mi" }], "km")).toEqual(["It's under 2 km away."]);
    expect(bandLabel("10-25 mi", "km")).toBe("16 to 40 km");
    expect(bandLabel("10-25 mi")).toBe("10-25 mi");
    expect(bandLabel("online", "km")).toBe("Online");
  });
});
