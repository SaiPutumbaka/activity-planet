import { describe, expect, it } from "vitest";

import { isNotFoundError } from "../index";

describe("isNotFoundError", () => {
  it("reads PT404 (migration 69) and the older P0002 as not found", () => {
    expect(isNotFoundError({ code: "PT404", message: "not_found" })).toBe(true);
    expect(isNotFoundError({ code: "P0002", message: "place_not_found" })).toBe(true);
  });
  it("is false for other errors and non-errors", () => {
    expect(isNotFoundError({ code: "42501", message: "forbidden" })).toBe(false);
    expect(isNotFoundError({ code: "PGRST202" })).toBe(false);
    expect(isNotFoundError(null)).toBe(false);
    expect(isNotFoundError(new Error("not_found"))).toBe(false);
    expect(isNotFoundError({ code: 404 })).toBe(false);
  });
});
