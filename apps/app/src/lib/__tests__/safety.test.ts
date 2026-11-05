import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

import {
  REPORT_REASONS,
  REPORT_REASON_LABELS,
  blockWarningText,
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
});
