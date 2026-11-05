import { describe, expect, it } from "vitest";

import {
  listingFromInput,
  listingRemovalErrorCode,
  listingRemovalErrorMessage,
  listingRemovalRpcArgs,
  parseListingRemoval,
} from "../listing-removal";

const ID = "0b9f2c1e-8d1a-4c33-9f0e-1a2b3c4d5e6f";
const base = {
  eventId: null,
  listing: "",
  scope: "item",
  name: "Sam Organizer",
  email: " Sam@Example.org ",
  relationship: "organizer",
  reason: "",
};

describe("listingFromInput", () => {
  it("reads ids and Activity Planet links as event ids", () => {
    expect(listingFromInput(ID)).toEqual({ eventId: ID, url: null });
    expect(listingFromInput(`https://app.example/events/${ID}`).eventId).toBe(ID);
    expect(listingFromInput(`https://site.example/e/${ID}?x=1`).eventId).toBe(ID);
  });
  it("keeps other links as the listing URL", () => {
    expect(listingFromInput("https://calendar.example.org/e/1")).toEqual({
      eventId: null,
      url: "https://calendar.example.org/e/1",
    });
    expect(listingFromInput("  ")).toEqual({ eventId: null, url: null });
  });
});

describe("parseListingRemoval", () => {
  it("accepts a prefilled event id", () => {
    const r = parseListingRemoval({ ...base, eventId: ID });
    expect(r).toMatchObject({
      ok: true,
      value: { eventId: ID, url: null, email: "sam@example.org" },
    });
  });
  it("accepts a source page link with scope source", () => {
    const r = parseListingRemoval({
      ...base,
      listing: "https://cal.example.org/",
      scope: "source",
    });
    expect(r).toMatchObject({
      ok: true,
      value: { url: "https://cal.example.org/", scope: "source" },
    });
    if (r.ok) expect(listingRemovalRpcArgs(r.value).p_event).toBeNull();
  });
  it("names the first problem", () => {
    expect(parseListingRemoval({ ...base, name: "S" })).toEqual({
      ok: false,
      error: "name_required",
    });
    expect(parseListingRemoval({ ...base, email: "no" })).toEqual({
      ok: false,
      error: "invalid_email",
    });
    expect(parseListingRemoval({ ...base, relationship: "fan" })).toEqual({
      ok: false,
      error: "invalid_relationship",
    });
    expect(parseListingRemoval({ ...base, scope: "all" })).toEqual({
      ok: false,
      error: "invalid_scope",
    });
    expect(parseListingRemoval(base)).toEqual({ ok: false, error: "listing_required" });
    expect(parseListingRemoval({ ...base, listing: "http://x.example" })).toEqual({
      ok: false,
      error: "invalid_url",
    });
    expect(parseListingRemoval({ ...base, eventId: ID, reason: "x".repeat(2001) })).toEqual({
      ok: false,
      error: "too_long",
    });
    expect(parseListingRemoval(null)).toEqual({ ok: false, error: "bad_request" });
  });
});

describe("messages", () => {
  it("maps known codes and hides the rest", () => {
    expect(listingRemovalErrorCode("not_imported")).toBe("not_imported");
    expect(listingRemovalErrorCode("permission denied for table")).toBe("unavailable");
    expect(listingRemovalErrorMessage("not_imported")).toContain("Report");
  });
});
