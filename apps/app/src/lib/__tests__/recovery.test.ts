import { beforeEach, describe, expect, it, vi } from "vitest";
import { markRecoveryVerified, takeRecoveryVerified } from "../recovery";

describe("recovery mark", () => {
  beforeEach(() => {
    const m = new Map<string, string>();
    vi.stubGlobal("sessionStorage", {
      getItem: (k: string) => m.get(k) ?? null,
      setItem: (k: string, v: string) => void m.set(k, v),
      removeItem: (k: string) => void m.delete(k),
    });
  });

  it("is needed, used once, and expires", () => {
    expect(takeRecoveryVerified(1000)).toBe(false);
    markRecoveryVerified(1000);
    expect(takeRecoveryVerified(2000)).toBe(true);
    expect(takeRecoveryVerified(2000)).toBe(false);
    markRecoveryVerified(0);
    expect(takeRecoveryVerified(16 * 60 * 1000)).toBe(false);
  });
});
