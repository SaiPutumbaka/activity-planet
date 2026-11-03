import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

const {
  CLAIM_AGREEMENT_VERSION,
  canManageChapter,
  chapterErrorMessage,
  chapterPlaceLabel,
  claimFormErrors,
  claimStatusView,
  emptyClaimForm,
  fieldForClaimError,
  isGsuBranded,
  memberActions,
  parsePublicCard,
  sortMembers,
  toClaimArgs,
  toManagedChapters,
} = await import("../chapters");

describe("toClaimArgs", () => {
  it("sends an area claim with the area and no organization fields", () => {
    const values = {
      ...emptyClaimForm("area"),
      areaId: "area-1",
      proposedName: "  Pickup in O4W ",
      rsoName: "ignored for areas",
      pinUrl: "https://ignored.example",
      motivation: "Tuesdays",
      agreed: true,
    };
    expect(toClaimArgs(values, { hubId: "hub-1", orgId: "org-1" })).toEqual({
      kind: "area",
      hub_id: "hub-1",
      area_id: "area-1",
      proposed_name: "Pickup in O4W",
      motivation: "Tuesdays",
      agreement_version: CLAIM_AGREEMENT_VERSION,
    });
  });

  it("takes an org claim's organization and campus from the membership", () => {
    const values = {
      ...emptyClaimForm("org"),
      proposedName: "Chess Club",
      rsoName: "GSU Chess Club",
      pinUrl: "https://example.org/chess",
      officerRole: "President",
      referenceName: "",
      agreed: true,
    };
    expect(toClaimArgs(values, { hubId: "hub-1", orgId: "org-1", campusId: "campus-1" })).toEqual({
      kind: "org",
      hub_id: "hub-1",
      org_id: "org-1",
      campus_id: "campus-1",
      proposed_name: "Chess Club",
      rso_name: "GSU Chess Club",
      pin_url: "https://example.org/chess",
      officer_role_text: "President",
      agreement_version: CLAIM_AGREEMENT_VERSION,
    });
  });

  it("sends only the chapter id when claiming an existing chapter", () => {
    const args = toClaimArgs(
      { ...emptyClaimForm("area"), areaId: "area-9", agreed: true },
      { hubId: "hub-1", chapterId: "ch-1" },
    );
    expect(args).toEqual({
      kind: "area",
      hub_id: "hub-1",
      chapter_id: "ch-1",
      agreement_version: CLAIM_AGREEMENT_VERSION,
    });
  });
});

describe("claimFormErrors", () => {
  it("passes a complete form", () => {
    expect(claimFormErrors({ ...emptyClaimForm("area"), areaId: "a", agreed: true })).toBeNull();
  });

  it("needs the agreement, an area and an https link", () => {
    const errors = claimFormErrors({ ...emptyClaimForm("area"), pinUrl: "http://x.org" });
    expect(errors?.agreed).toBeTruthy();
    expect(errors?.areaId).toBe("Pick a neighborhood.");
    expect(errors?.pinUrl).toBe("Links start with https://.");
  });

  it("checks the name length only when a name is given", () => {
    expect(
      claimFormErrors({ ...emptyClaimForm("org"), proposedName: "x", agreed: true })?.proposedName,
    ).toBeTruthy();
  });
});

describe("memberActions", () => {
  const base = { viewerId: "me", organizerCount: 1 };

  it("lets an organizer set member or captain on others but not touch another organizer", () => {
    expect(
      memberActions({
        ...base,
        viewerRole: "organizer",
        isModerator: false,
        target: { user_id: "u1", role: "member" },
      }),
    ).toEqual({ roles: ["captain"], canRemove: true });
    expect(
      memberActions({
        ...base,
        organizerCount: 2,
        viewerRole: "organizer",
        isModerator: false,
        target: { user_id: "u2", role: "organizer" },
      }),
    ).toEqual({ roles: [], canRemove: false });
  });

  it("keeps the last organizer", () => {
    expect(
      memberActions({
        ...base,
        viewerRole: "organizer",
        isModerator: false,
        target: { user_id: "me", role: "organizer" },
      }),
    ).toEqual({ roles: [], canRemove: false });
    expect(
      memberActions({
        ...base,
        viewerRole: null,
        isModerator: true,
        target: { user_id: "u3", role: "organizer" },
      }),
    ).toEqual({ roles: [], canRemove: false });
  });

  it("lets an organizer step down when another organizer remains", () => {
    expect(
      memberActions({
        ...base,
        organizerCount: 2,
        viewerRole: "organizer",
        isModerator: false,
        target: { user_id: "me", role: "organizer" },
      }).roles,
    ).toEqual(["member", "captain"]);
  });

  it("lets a captain remove members and captains but change no roles", () => {
    expect(
      memberActions({
        ...base,
        viewerRole: "captain",
        isModerator: false,
        target: { user_id: "u1", role: "captain" },
      }),
    ).toEqual({ roles: [], canRemove: true });
    expect(
      memberActions({
        ...base,
        organizerCount: 2,
        viewerRole: "captain",
        isModerator: false,
        target: { user_id: "u2", role: "organizer" },
      }).canRemove,
    ).toBe(false);
  });

  it("lets a moderator grant organizer", () => {
    expect(
      memberActions({
        ...base,
        viewerRole: null,
        isModerator: true,
        target: { user_id: "u1", role: "member" },
      }),
    ).toEqual({ roles: ["captain", "organizer"], canRemove: true });
  });

  it("gives a plain member nothing", () => {
    expect(
      memberActions({
        ...base,
        viewerRole: "member",
        isModerator: false,
        target: { user_id: "u1", role: "member" },
      }),
    ).toEqual({ roles: [], canRemove: false });
  });
});

describe("small mappers", () => {
  it("sorts organizers, captains, then members, oldest first", () => {
    const rows = sortMembers([
      { id: "a", role: "member" as const, joined_at: "2026-01-01" },
      { id: "b", role: "captain" as const, joined_at: "2026-02-01" },
      { id: "c", role: "organizer" as const, joined_at: "2026-03-01" },
      { id: "d", role: "captain" as const, joined_at: "2026-01-15" },
    ]);
    expect(rows.map((r) => r.id)).toEqual(["c", "d", "b", "a"]);
  });

  it("knows who manages a chapter", () => {
    expect(canManageChapter("captain", false)).toBe(true);
    expect(canManageChapter("organizer", false)).toBe(true);
    expect(canManageChapter("member", false)).toBe(false);
    expect(canManageChapter(null, true)).toBe(true);
  });

  it("labels places and claim states", () => {
    expect(chapterPlaceLabel({ areas: { name: "Midtown" } })).toBe("Midtown");
    expect(
      chapterPlaceLabel({ org_campuses: { name: "Atlanta" }, organizations: { name: "GSU" } }),
    ).toBe("Atlanta");
    expect(claimStatusView("pending")).toEqual({ label: "In review", tone: "warning" });
    expect(claimStatusView("rejected").tone).toBe("danger");
  });

  it("puts the GSU disclaimer only on Georgia State surfaces", () => {
    expect(isGsuBranded("Georgia State University")).toBe(true);
    expect(isGsuBranded(null, "GSU Atlanta")).toBe(true);
    expect(isGsuBranded("Midtown", null)).toBe(false);
  });

  it("joins managed chapters to their hubs and drops inactive ones", () => {
    const row = {
      chapter_id: "ch-1",
      slug: "chess",
      name: "Chess",
      role: "captain" as const,
      hub_id: "hub-1",
      hub_slug: "chess",
      hub_name: "Chess",
      org_id: "",
      campus_id: "",
      area_id: "area-1",
      place_label: "Midtown",
      is_active: true,
    };
    const hub = {
      id: "hub-1",
      slug: "chess",
      name: "Chess",
      emoji: "x",
      min_age: 18,
      scope: "general",
      is_active: true,
    };
    const out = toManagedChapters([row, { ...row, chapter_id: "ch-2", is_active: false }], [hub]);
    expect(out).toEqual([
      {
        id: "ch-1",
        slug: "chess",
        name: "Chess",
        role: "captain",
        hubId: "hub-1",
        campusId: null,
        placeLabel: "Midtown",
        isActive: true,
        hub,
      },
    ]);
  });

  it("parses the public card and refuses malformed answers", () => {
    const card = parsePublicCard({
      id: "c",
      slug: "s",
      name: "N",
      description: "",
      cover_url: null,
      hub: { id: "h", slug: "hs", name: "Hub", emoji: "x" },
      owner_kind: "area",
      org: null,
      campus: null,
      area: { slug: "midtown", name: "Midtown" },
      place_label: "Midtown",
      rso_name: null,
      pin_url: null,
      verified: true,
      member_count: "4",
      upcoming_public_events: 2,
    });
    expect(card?.member_count).toBe(4);
    expect(card?.area?.name).toBe("Midtown");
    expect(parsePublicCard(null)).toBeNull();
    expect(parsePublicCard({ id: 1 })).toBeNull();
  });

  it("maps errors to sentences and fields", () => {
    expect(chapterErrorMessage({ message: "chapter_has_organizer" })).toBe(
      "This chapter already has an organizer.",
    );
    expect(chapterErrorMessage({ message: "x", code: "42501" })).toMatch(/verified members/);
    expect(chapterErrorMessage({ message: "weird_code" })).toBe("Couldn't do that (weird code).");
    expect(fieldForClaimError({ message: "pin_url_invalid" })).toBe("pinUrl");
    expect(fieldForClaimError({ message: "too_many_claims" })).toBeNull();
  });
});
