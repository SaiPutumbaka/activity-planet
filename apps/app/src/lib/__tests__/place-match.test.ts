import { describe, expect, it } from "vitest";

import {
  placeSearchMatches,
  placeSearchNeedle,
  sameOrCloseName,
  similarity,
  trigrams,
} from "../place-match";

/** Values from Postgres pg_trgm (show_trgm, similarity). */
describe("pg_trgm on the client (D-042 slice 11)", () => {
  it("builds the same trigrams", () => {
    expect([...trigrams("cat")].sort()).toEqual(["  c", " ca", "at ", "cat"]);
    expect([...trigrams("Cat, CAT!")].sort()).toEqual(["  c", " ca", "at ", "cat"]);
  });
  it("gives the same similarity", () => {
    expect(similarity("word", "words").toFixed(6)).toBe("0.571429");
    expect(similarity("Grant Park", "grant park")).toBe(1);
    expect(similarity("", "abc")).toBe(0);
  });
  it("same or close name at 0.45", () => {
    expect(sameOrCloseName("Riverside Courts", "riverside courts")).toBe(true);
    expect(sameOrCloseName("Riverside Courts", "Riverside Court")).toBe(true);
    expect(sameOrCloseName("Riverside Courts", "Downtown Library")).toBe(false);
  });
  it("searches like places_in_view's p_query", () => {
    expect(placeSearchNeedle(" a ")).toBeNull();
    expect(placeSearchNeedle("x".repeat(61))).toBeNull();
    expect(placeSearchNeedle("  Park ")).toBe("park");
    expect(placeSearchMatches("park", "Grant Park")).toBe(true);
    expect(placeSearchMatches("leipzig", "Sporthalle", "Leipzig")).toBe(true);
    expect(placeSearchMatches("library", "Grant Park")).toBe(false);
  });
});
