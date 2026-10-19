import { describe, expect, it } from "vitest";

import { safeInternalPath, signupSchema } from "../auth";
import { ageOn, birthDateSchema, handleSchema, meetsMinimumAge, MINIMUM_AGE } from "../profile";
import { stripControlChars } from "../sanitize";

describe("stripControlChars", () => {
  it("removes control characters but keeps tabs, newlines and trims", () => {
    expect(stripControlChars("  hi\u0000 there\u001F\n ")).toBe("hi there\n".trim());
    expect(stripControlChars("a\tb")).toBe("a\tb");
  });
});

describe("safeInternalPath", () => {
  it("accepts internal paths and rejects everything else", () => {
    expect(safeInternalPath("/events/abc")).toBe("/events/abc");
    expect(safeInternalPath("//evil.example")).toBe("/");
    expect(safeInternalPath("/" + String.fromCharCode(92) + "evil.example")).toBe("/");
    expect(safeInternalPath("https://evil.example")).toBe("/");
    expect(safeInternalPath(null, "/home")).toBe("/home");
  });
});

describe("handleSchema", () => {
  it("enforces length, charset and reserved names", () => {
    expect(handleSchema.safeParse("sai_p").success).toBe(true);
    expect(handleSchema.safeParse("ab").success).toBe(false);
    expect(handleSchema.safeParse("has space").success).toBe(false);
    expect(handleSchema.safeParse("Admin").success).toBe(false);
  });
});

describe("signupSchema", () => {
  it("lowercases email and requires matching passwords", () => {
    const ok = signupSchema.safeParse({
      email: "Student@GSU.edu ",
      password: "longenough",
      confirmPassword: "longenough",
    });
    expect(ok.success).toBe(true);
    if (ok.success) expect(ok.data.email).toBe("student@gsu.edu");
    expect(
      signupSchema.safeParse({
        email: "a@b.co",
        password: "longenough",
        confirmPassword: "different",
      }).success,
    ).toBe(false);
  });
});

describe("birth dates and the 18+ rule", () => {
  const today = new Date(Date.UTC(2027, 0, 11)); // launch day

  it("validates real calendar dates only", () => {
    expect(birthDateSchema.safeParse("2004-02-29").success).toBe(true);
    expect(birthDateSchema.safeParse("2005-02-29").success).toBe(false);
    expect(birthDateSchema.safeParse("March 5 2000").success).toBe(false);
  });

  it("computes age on calendar parts, not timestamps", () => {
    expect(ageOn("2009-01-11", today)).toBe(MINIMUM_AGE);
    expect(ageOn("2009-01-12", today)).toBe(MINIMUM_AGE - 1);
    expect(meetsMinimumAge("2009-01-11", today)).toBe(true);
    expect(meetsMinimumAge("2009-01-12", today)).toBe(false);
  });
});
