import { describe, expect, it } from "vitest";

import { DEFAULT_TIMEZONE, viewerZone } from "@/lib/datetime";

describe("viewerZone", () => {
  it("uses the device's zone, so a plan posted in London is in London time", () => {
    expect(viewerZone("Europe/London")).toBe("Europe/London");
  });

  it("falls back to the default zone only when the device has none", () => {
    expect(viewerZone(null)).toBe(DEFAULT_TIMEZONE);
  });
});
