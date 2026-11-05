import { describe, expect, it } from "vitest";

import {
  parseTakedownRequest,
  takedownErrorCode,
  takedownErrorMessage,
  takedownRpcArgs,
} from "../takedown";

// The same rules as submit_takedown_request (migration 52; supabase/tests/ncii_takedown.sql
// section 2).
const good = {
  name: "  Pat Requester ",
  email: " Pat@Example.com ",
  relationship: "self",
  locations: "https://activityplanet.app/u/someone",
  description: "",
  goodFaith: true,
  signature: "Pat Requester",
  involvesMinor: false,
};

describe("parseTakedownRequest", () => {
  it("accepts a complete request and normalizes it", () => {
    const r = parseTakedownRequest(good);
    expect(r).toEqual({
      ok: true,
      value: { ...good, name: "Pat Requester", email: "pat@example.com" },
    });
    if (r.ok) {
      expect(takedownRpcArgs(r.value)).toEqual({
        p_name: "Pat Requester",
        p_email: "pat@example.com",
        p_relationship: "self",
        p_locations: good.locations,
        p_good_faith: true,
        p_signature: "Pat Requester",
        p_description: "",
        p_involves_minor: false,
      });
    }
  });

  it.each([
    [{ name: "P" }, "name_required"],
    [{ email: "not-an-email" }, "invalid_email"],
    [{ email: `${"a".repeat(250)}@x.co` }, "invalid_email"],
    [{ relationship: "friend" }, "invalid_relationship"],
    [{ locations: " " }, "location_required"],
    [{ locations: "x".repeat(4001) }, "too_long"],
    [{ description: "x".repeat(2001) }, "too_long"],
    [{ goodFaith: false }, "good_faith_required"],
    [{ goodFaith: "yes" }, "good_faith_required"],
    [{ signature: " " }, "signature_required"],
  ])("refuses %j with %s", (patch, error) => {
    expect(parseTakedownRequest({ ...good, ...patch })).toEqual({ ok: false, error });
  });

  it("refuses a body that is not an object", () => {
    expect(parseTakedownRequest(null)).toEqual({ ok: false, error: "bad_request" });
    expect(parseTakedownRequest("x")).toEqual({ ok: false, error: "bad_request" });
  });

  it("keeps the authorized relationship and the minor flag", () => {
    const r = parseTakedownRequest({ ...good, relationship: "authorized", involvesMinor: true });
    expect(r.ok && r.value.relationship === "authorized" && r.value.involvesMinor).toBe(true);
  });
});

describe("takedown errors", () => {
  it("maps database messages to codes and codes to plain words", () => {
    expect(takedownErrorCode("rate_limited")).toBe("rate_limited");
    expect(takedownErrorCode("permission denied for function x")).toBe("unavailable");
    expect(takedownErrorCode(null)).toBe("unavailable");
    expect(takedownErrorMessage("invalid_email")).toMatch(/email/);
    expect(takedownErrorMessage("whatever")).toBe(takedownErrorMessage("unavailable"));
  });
});
