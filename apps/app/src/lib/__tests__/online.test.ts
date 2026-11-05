import { describe, expect, it } from "vitest";

import { OfflineError, looksLikeNetworkError, routeErrorCopy } from "@/lib/online";

describe("routeErrorCopy", () => {
  it("says offline when the device has no connection, whatever the error", () => {
    const c = routeErrorCopy(new Error("anything"), false);
    expect(c.offline).toBe(true);
    expect(c.title).toBe("You're offline");
  });

  it("treats a fetch failure as offline even when the browser thinks it is online", () => {
    expect(routeErrorCopy(new TypeError("Failed to fetch"), true).offline).toBe(true);
    expect(routeErrorCopy({ message: "TypeError: Load failed" }, true).offline).toBe(true);
    expect(routeErrorCopy(new OfflineError(), true).offline).toBe(true);
  });

  it("keeps the error's own message otherwise", () => {
    const c = routeErrorCopy(new Error("Plan not found"), true);
    expect(c).toEqual({ title: "Something broke", body: "Plan not found", offline: false });
    expect(routeErrorCopy(null, true).body).toBe("Try again in a moment.");
  });
});

describe("looksLikeNetworkError", () => {
  it("ignores ordinary errors", () => {
    expect(looksLikeNetworkError(new Error("permission denied"))).toBe(false);
    expect(looksLikeNetworkError(undefined)).toBe(false);
  });
});
