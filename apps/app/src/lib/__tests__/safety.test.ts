import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

import {
  REPORT_REASONS,
  REPORT_REASON_LABELS,
  REPORT_SUBJECTS,
  attendeeName,
  blockWarningText,
  blockedIdSet,
  blockedOnText,
  blockedText,
  reportSentText,
  reportTitle,
  safetyErrorCode,
  safetyErrorMessage,
} from "../safety";

describe("safety", () => {
  it("labels every reason without student-only or city-only wording", () => {
    for (const r of REPORT_REASONS) {
      expect(REPORT_REASON_LABELS[r].length).toBeGreaterThan(0);
      expect(REPORT_REASON_LABELS[r]).not.toMatch(/student|campus|GSU|Georgia State|Atlanta/i);
    }
  });

  it("reads error codes and turns them into sentences", () => {
    expect(safetyErrorCode({ message: "own_item" })).toBe("own_item");
    expect(safetyErrorCode({ message: "Some sentence." })).toBe("");
    expect(safetyErrorMessage({ message: "rate_limited" })).toMatch(/tomorrow/);
    expect(safetyErrorMessage(new Error("boom boom"))).toMatch(/Try again/);
  });

  it("words the co-attendance warning", () => {
    expect(blockWarningText(0)).toBeNull();
    expect(blockWarningText(1)).toMatch(/^Someone you blocked/);
    expect(blockWarningText(2)).toMatch(/^2 people you blocked/);
  });

  it("names attendee rows: profile, blocked member, deleted user", () => {
    const blocked = blockedIdSet([{ user_id: "b" }]);
    expect(attendeeName({ first_name: "Ana" }, "a", blocked)).toBe("Ana");
    expect(attendeeName(null, "b", blocked)).toBe("Blocked member");
    expect(attendeeName(null, "c", blocked)).toBe("Deleted user");
    expect(attendeeName(undefined, "b", blockedIdSet(undefined))).toBe("Deleted user");
  });

  it("titles reports by kind", () => {
    expect(reportTitle("event")).toBe("Report this plan");
    expect(reportTitle("chapter")).toBe("Report this chapter");
    expect(reportTitle("hub")).toBe("Report this hub");
    expect(reportTitle("profile")).toBe("Report this profile");
    expect(reportTitle("profile", "Sam")).toBe("Report Sam");
    for (const s of Object.values(REPORT_SUBJECTS)) {
      expect(s).not.toMatch(/student|campus|GSU|Georgia State|Atlanta/i);
    }
  });

  it("words the report answer without revealing someone else's hide", () => {
    expect(reportSentText({ already: true, hidden: false })).toMatch(/already reported/);
    expect(reportSentText({ already: false, hidden: true })).toMatch(/hidden/);
    expect(reportSentText({ already: false, hidden: false })).toBe(
      "Thanks. A moderator will look at it.",
    );
  });

  it("words the block toast with shared plans", () => {
    expect(blockedText("Sam", { shared_upcoming: 0 })).toBe("You blocked Sam.");
    expect(blockedText("Sam", { shared_upcoming: 1 })).toMatch(/1 upcoming plan;/);
    expect(blockedText("Sam", { shared_upcoming: 3 })).toMatch(/3 upcoming plans;/);
  });

  it("dates the blocked list", () => {
    expect(blockedOnText("2026-11-05T12:00:00Z", "UTC")).toBe("Blocked Nov 5, 2026");
    expect(blockedOnText("nope")).toBe("Blocked");
  });
});
