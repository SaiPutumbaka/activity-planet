import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

import {
  MOD_ACTIONS,
  addPlaceArgs,
  decodeModQueue,
  describeChange,
  duplicateCandidates,
  factsOf,
  ownPinActions,
  placeChanges,
  placeErrorCode,
  placeErrorMessage,
  reportReasonLabel,
} from "../place-contributions";

describe("addPlaceArgs", () => {
  it("sends a private pin with no hubs and no blank fields", () => {
    expect(
      addPlaceArgs({
        name: "  Back court ",
        kind: "court_field",
        lat: 33.7512345678,
        lng: -84.3912345678,
        isPublic: false,
        website: " ",
        hours: "",
      }),
    ).toEqual({
      name: "Back court",
      kind: "court_field",
      lat: 33.751235,
      lng: -84.391235,
      is_public: false,
    });
  });

  it("sends the confirmation, at most three distinct hubs and allow_duplicate for a public place", () => {
    const args = addPlaceArgs({
      name: "Courts",
      kind: "court_field",
      lat: 1,
      lng: 2,
      isPublic: true,
      confirmPublic: true,
      hubIds: ["a", "a", "b", "c", "d"],
      website: "https://example.org",
      hours: "24/7",
      allowDuplicate: true,
    });
    expect(args).toMatchObject({
      is_public: true,
      confirm_public: true,
      hub_ids: ["a", "b", "c"],
      website: "https://example.org",
      opening_hours: "24/7",
      allow_duplicate: true,
    });
  });

  it("never sends confirm_public for a private pin", () => {
    expect(
      addPlaceArgs({
        name: "X1",
        kind: "spot",
        lat: 0,
        lng: 0,
        isPublic: false,
        confirmPublic: true,
      }),
    ).not.toHaveProperty("confirm_public");
  });
});

describe("errors", () => {
  it("explains the home and private venue refusals without saying where home is", () => {
    expect(placeErrorMessage({ message: "near_your_home", code: "23514" })).toMatch(
      /150 m of your saved home/,
    );
    expect(placeErrorMessage({ message: "near_private_venue" })).toMatch(/50 m/);
    expect(placeErrorMessage({ message: "rate_limited" })).toMatch(/limit for today/);
    expect(
      placeErrorMessage({ message: "permission denied for function add_place", code: "42501" }),
    ).toBe("Sign in to do that.");
    expect(placeErrorMessage({ message: "some_new_code" })).toBe(
      "Couldn't do that (some new code).",
    );
    expect(placeErrorMessage(new Error("Failed to fetch"))).toMatch(/connection/);
    expect(placeErrorCode({ message: "hub_required" })).toBe("hub_required");
    expect(placeErrorCode({ message: "Something odd happened" })).toBe("");
  });

  it("reads duplicate candidates from the error detail", () => {
    const err = {
      message: "duplicate_candidates",
      details: JSON.stringify([
        { id: "p1", name: "Court One", kind: "court_field", distance_m: 14.6, mine: false },
        { id: "p2", name: "", kind: "park", distance_m: 40, mine: true },
        { name: "no id" },
      ]),
    };
    expect(duplicateCandidates(err)).toEqual([
      { id: "p1", name: "Court One", kind: "court_field", distanceM: 15, mine: false },
      { id: "p2", name: "Park or garden", kind: "park", distanceM: 40, mine: true },
    ]);
    expect(duplicateCandidates({ message: "duplicate_candidates", details: "not json" })).toEqual(
      [],
    );
    expect(duplicateCandidates({ message: "near_your_home", details: "[]" })).toEqual([]);
  });
});

describe("placeChanges", () => {
  const before = factsOf({
    name: "Court One",
    kind: "court_field",
    hours: null,
    website: null,
    address: "1 Main St",
  });

  it("is empty when nothing changed but whitespace", () => {
    expect(placeChanges(before, { ...before, name: " Court One  " })).toEqual({});
  });

  it("sends only the changed fields in the server's names", () => {
    expect(
      placeChanges(before, {
        ...before,
        name: "Court 1",
        hours: "Mo-Su 08:00-20:00",
        address: "",
        closed: true,
      }),
    ).toEqual({
      name: "Court 1",
      opening_hours: "Mo-Su 08:00-20:00",
      address_text: "",
      closed: true,
    });
  });
});

describe("ownPinActions", () => {
  it("offers edit, share and delete on a private pin", () => {
    expect(ownPinActions({ mine: true, source: "user", private: true, pending: false })).toEqual({
      edit: true,
      makePublic: true,
      makePrivate: false,
      remove: true,
    });
  });
  it("offers withdrawing a pending request", () => {
    expect(
      ownPinActions({ mine: true, source: "user", private: false, pending: true }).makePrivate,
    ).toBe(true);
  });
  it("offers nothing on a reviewed public place, even the creator's", () => {
    expect(ownPinActions({ mine: true, source: "user", private: false, pending: false })).toEqual({
      edit: false,
      makePublic: false,
      makePrivate: false,
      remove: false,
    });
  });
});

describe("decodeModQueue", () => {
  const place = {
    id: "p1",
    name: "Court Two",
    kind: "court_field",
    kind_label: "Court or field",
    lat: -61.6,
    lng: -129.6,
    source: "user",
    status: "pending",
    is_public: true,
    locked_fields: [],
    member_added: true,
    osm_url: "javascript:alert(1)",
    creator_account_days: 3,
    hubs: [{ id: "h1", name: "Basketball", emoji: "🏀", via: "member" }],
    nearby: [{ id: "p9", name: "Court One", kind: "court_field", distance_m: 80 }],
  };

  it("decodes the three kinds and drops malformed items", () => {
    const q = decodeModQueue({
      v: 1,
      counts: { places: 1, edits: 1, reports: 1 },
      items: [
        { kind: "place", id: "p1", created_at: "2026-11-04T10:00:00Z", place, own: false },
        {
          kind: "edit",
          id: "e1",
          place,
          changes: { name: "Court 2" },
          current: { name: "Court Two" },
          note: "Sign says 2",
          move_m: null,
        },
        {
          kind: "reports",
          id: "p1",
          place,
          open: 2,
          reporters: 2,
          reasons: { closed: 1, spam: 1, bad: "x" },
          reports: [{ id: "r1", reason: "closed", note: null, created_at: "2026-11-04T10:00:00Z" }],
        },
        { kind: "nope", id: "x", place },
        { kind: "place", id: "p2" },
      ],
    });
    expect(q.counts).toEqual({ places: 1, edits: 1, reports: 1 });
    expect(q.items.map((i) => i.kind)).toEqual(["place", "edit", "reports"]);
    expect(q.items[0]!.place.osmUrl).toBeNull();
    expect(q.items[0]!.place.creatorAccountDays).toBe(3);
    expect(q.items[1]!.note).toBe("Sign says 2");
    expect(q.items[2]!.reasons).toEqual({ closed: 1, spam: 1 });
    expect(q.items[2]!.reports).toHaveLength(1);
  });

  it("is empty for anything else", () => {
    expect(decodeModQueue(null)).toEqual({
      items: [],
      counts: { places: 0, edits: 0, reports: 0 },
    });
  });
});

describe("labels", () => {
  it("describes changes and reasons", () => {
    expect(describeChange("name", "Old", "New")).toBe("Name: Old → New");
    expect(describeChange("website", "", "https://x.org")).toBe("Website: (empty) → https://x.org");
    expect(describeChange("closed", false, true)).toBe("Closed: no → yes");
    expect(describeChange("kind", "park", "court_field")).toBe(
      "Kind: Park or garden → Court or field",
    );
    expect(describeChange("hubs_add", undefined, ["a", "b"])).toBe("Add hubs: 2 hubs");
    expect(reportReasonLabel("private_residence")).toBe("It's someone's home");
    expect(reportReasonLabel("weird")).toBe("Something else");
  });

  it("puts the primary action last for every kind", () => {
    expect(MOD_ACTIONS.place.at(-1)?.action).toBe("approve");
    expect(MOD_ACTIONS.edit.at(-1)?.action).toBe("approve");
    expect(MOD_ACTIONS.reports.at(-1)?.action).toBe("dismiss");
  });
});
