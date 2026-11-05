import { describe, expect, it } from "vitest";

import {
  checkFeedUrl,
  claimStatusLabel,
  failureText,
  organizerErrorMessage,
  proofCopies,
  sortHosts,
} from "../index";

const TOKEN = "ap-verify-abcdefghijklmnopqrstuvwx";
const proofs = {
  meta: `<meta name="activityplanet-verification" content="${TOKEN}">`,
  well_known: {
    url: "https://example.org/.well-known/activityplanet-verification.txt",
    content: TOKEN,
  },
  dns_txt: { name: "_activityplanet.example.org", value: TOKEN },
  feed: `Add ${TOKEN} to the calendar's description.`,
};

describe("proofCopies", () => {
  it("gives each method its own values to copy", () => {
    expect(proofCopies({ method: "meta", token: TOKEN, proofs })[0]!.value).toContain(TOKEN);
    expect(proofCopies({ method: "well_known", token: TOKEN, proofs }).map((c) => c.value)).toEqual(
      [proofs.well_known.url, TOKEN],
    );
    expect(proofCopies({ method: "dns_txt", token: TOKEN, proofs }).map((c) => c.value)).toEqual([
      "_activityplanet.example.org",
      "TXT",
      TOKEN,
    ]);
    expect(proofCopies({ method: "feed", token: TOKEN, proofs })).toEqual([
      { label: "Code for the calendar's description", value: TOKEN },
    ]);
  });
  it("is empty once the token is gone (not pending)", () => {
    expect(proofCopies({ method: "meta", token: null, proofs: null })).toEqual([]);
  });
});

describe("checkFeedUrl", () => {
  it("accepts https and turns webcal into https", () => {
    expect(checkFeedUrl(" webcal://calendar.example.org/a.ics ")).toEqual({
      ok: true,
      url: "https://calendar.example.org/a.ics",
    });
    expect(checkFeedUrl("https://x.example/c.ics").ok).toBe(true);
  });
  it("refuses plain http, passwords and junk", () => {
    expect(checkFeedUrl("http://x.example/c.ics").ok).toBe(false);
    expect(checkFeedUrl("https://a:b@x.example/c.ics").ok).toBe(false);
    expect(checkFeedUrl("not a link").ok).toBe(false);
    expect(checkFeedUrl("").ok).toBe(false);
  });
});

describe("labels and errors", () => {
  it("labels statuses", () => {
    expect(claimStatusLabel({ status: "pending" })).toBe("Waiting for proof");
    expect(claimStatusLabel({ status: "verified" })).toBe("Verified");
  });
  it("explains failures, robots.txt included", () => {
    expect(failureText("fetch_failed:robots_disallowed")).toContain("robots.txt");
    expect(failureText("fetch_failed:timeout")).toBe("We couldn't read the page.");
    expect(failureText(null)).toBeNull();
  });
  it("maps database codes and never shows raw text", () => {
    expect(organizerErrorMessage({ message: "host_mismatch" })).toContain("doesn't match");
    expect(organizerErrorMessage({ message: "duplicate key value violates" })).toBe(
      "Something went wrong. Try again.",
    );
  });
  it("puts the registrable domain first", () => {
    expect(sortHosts(["events.example.org", "example.org", "example.org"])).toEqual([
      "example.org",
      "events.example.org",
    ]);
  });
});
