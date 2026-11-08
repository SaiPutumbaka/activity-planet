import { describe, expect, it } from "vitest";

import { OPEN_DATA_CREDITS, sourceLine } from "../index";

// packages/collector/test/adapters.test.ts checks these against the collector's registry.
describe("open-data credits", () => {
  it("City of Calgary carries the licence line Sai gave, word for word", () => {
    const cal = OPEN_DATA_CREDITS.find((c) => c.id === "calgary-city-events");
    expect(cal?.attribution).toBe(
      "Contains information licensed under the Open Government Licence – City of Calgary.",
    );
    expect(cal?.licence.url.startsWith("https://")).toBe(true);
  });

  it("the event page's source line is the attribution", () => {
    expect(
      sourceLine({
        attribution: OPEN_DATA_CREDITS[0]!.attribution,
        source_name: "City of Calgary Events",
      }),
    ).toBe("Contains information licensed under the Open Government Licence – City of Calgary.");
  });
});
