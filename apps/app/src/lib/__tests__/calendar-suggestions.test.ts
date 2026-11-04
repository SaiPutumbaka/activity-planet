import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

import {
  checkSuggestion,
  decodePending,
  decodeSuggestResult,
  suggestionErrorMessage,
} from "../calendar-suggestions";

describe("calendar suggestions", () => {
  it("checks the URL the way the server does", () => {
    expect(checkSuggestion("webcal://cal.aptest.gov/a.ics")).toEqual({
      check: { ok: true, url: "https://cal.aptest.gov/a.ics", host: "cal.aptest.gov" },
      error: null,
    });
    expect(checkSuggestion("https://localhost/").error).toMatch(/public web/);
    expect(checkSuggestion("aptest.org").error).toMatch(/full link/);
  });

  it("explains every server error in plain words", () => {
    expect(suggestionErrorMessage({ message: "url_denylisted" })).toMatch(/own website/);
    expect(suggestionErrorMessage({ message: "rate_limited" })).toMatch(/five for today/);
    expect(suggestionErrorMessage({ message: "queue_full" })).toMatch(/queue is full/);
    expect(
      suggestionErrorMessage({ message: "permission denied for function", code: "42501" }),
    ).toBe("Sign in to do that.");
    expect(suggestionErrorMessage({ message: "TypeError: Failed to fetch" })).toMatch(/connection/);
    expect(suggestionErrorMessage("weird")).toBe("Something went wrong. Try again.");
  });

  it("copy names no city, campus or audience (D-040)", () => {
    for (const code of ["url_denylisted", "rate_limited", "url_private_host", "queue_full"]) {
      expect(suggestionErrorMessage({ message: code })).not.toMatch(
        /atlanta|georgia|gsu|student|campus/i,
      );
    }
  });

  it("decodes results and the moderation queue", () => {
    expect(decodeSuggestResult({ status: "already_known", host: "a.org" })).toEqual({
      status: "already_known",
      host: "a.org",
    });
    expect(decodeSuggestResult(null)).toEqual({ status: "received", host: "" });
    expect(
      decodePending([
        {
          id: "1",
          url: "https://a.org/events",
          host: "a.org",
          suggest_count: 3,
          created_at: "2026-11-04T10:00:00Z",
          collector_regions: { label: "Freiburg" },
        },
        { id: 2 },
        { id: "3", url: "https://b.org/", collector_regions: null },
      ]),
    ).toEqual([
      {
        id: "1",
        url: "https://a.org/events",
        host: "a.org",
        suggestCount: 3,
        createdAt: "2026-11-04T10:00:00Z",
        regionLabel: "Freiburg",
      },
      {
        id: "3",
        url: "https://b.org/",
        host: "",
        suggestCount: 1,
        createdAt: "",
        regionLabel: null,
      },
    ]);
  });
});
