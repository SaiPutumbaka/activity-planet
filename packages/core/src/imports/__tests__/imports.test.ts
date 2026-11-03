import { describe, expect, it } from "vitest";

import {
  SUPPORT_EMAIL,
  importChips,
  listedByLine,
  notAffiliatedLine,
  removalMailto,
} from "../index";

const pin = {
  item_label: "Georgia State student org event",
  open_to_public: null,
  affiliated_org_name: "Georgia State University",
};
const localistPublic = {
  item_label: null,
  open_to_public: true,
  affiliated_org_name: "Georgia State University",
};

describe("importChips", () => {
  it("shows the source label for PIN items", () => {
    expect(importChips(pin)).toEqual(["Georgia State student org event"]);
  });
  it("shows Open to the public only when the source says so", () => {
    expect(importChips(localistPublic)).toEqual(["Open to the public"]);
    expect(importChips({ ...localistPublic, open_to_public: false })).toEqual([]);
    expect(importChips({ ...localistPublic, open_to_public: null })).toEqual([]);
  });
  it("is empty without labels", () => {
    expect(importChips(null)).toEqual([]);
    expect(importChips(undefined)).toEqual([]);
  });
});

describe("listedByLine", () => {
  it("names the source and the host", () => {
    expect(listedByLine("PIN, Georgia State student organizations", "Chess Club")).toBe(
      "Listed by PIN, Georgia State student organizations · Hosted by Chess Club",
    );
  });
  it("drops a host that repeats the source and falls back when there is no source", () => {
    expect(listedByLine("City Parks", "city parks")).toBe("Listed by City Parks");
    expect(listedByLine(null)).toBe("Listed by a public calendar");
  });
});

describe("notAffiliatedLine", () => {
  it("appears only for sources that belong to an organization", () => {
    expect(notAffiliatedLine(pin)).toBe(
      "Not affiliated with or endorsed by Georgia State University.",
    );
    expect(notAffiliatedLine({ ...pin, affiliated_org_name: null })).toBeNull();
    expect(notAffiliatedLine(null)).toBeNull();
  });
});

describe("removalMailto", () => {
  it("prefills a removal request to support", () => {
    const href = removalMailto({
      id: "e1",
      title: "Chess & Coffee",
      externalUrl: "https://example.com/e/1",
      appUrl: "https://app.example.com/events/e1",
    });
    expect(href.startsWith(`mailto:${SUPPORT_EMAIL}?subject=`)).toBe(true);
    const url = new URL(href);
    expect(url.searchParams.get("subject")).toBe("Removal request: Chess & Coffee");
    const body = url.searchParams.get("body") ?? "";
    expect(body).toContain("On Activity Planet: https://app.example.com/events/e1");
    expect(body).toContain("Original: https://example.com/e/1");
  });
  it("uses the id when there is no app link", () => {
    const body = new URL(removalMailto({ id: "e2", title: "T" })).searchParams.get("body");
    expect(body).toContain("Listing id: e2");
    expect(body).not.toContain("Original:");
  });
});
