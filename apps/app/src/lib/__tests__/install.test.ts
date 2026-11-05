import { afterEach, describe, expect, it, vi } from "vitest";

import { badgeCount } from "../app-badge";

describe("badgeCount", () => {
  it("adds unread chats, requests and notifications and ignores junk", () => {
    expect(badgeCount([2, 1, 3])).toBe(6);
    expect(badgeCount([undefined, null, -1, Number.NaN])).toBe(0);
    expect(badgeCount([5000])).toBe(999);
  });
});

describe("install", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  function stubBrowser(store: Map<string, string>) {
    vi.stubGlobal("window", {
      addEventListener: () => undefined,
      matchMedia: () => ({ matches: false, addEventListener: () => undefined }),
    });
    vi.stubGlobal("navigator", { userAgent: "test", maxTouchPoints: 0 });
    vi.stubGlobal("localStorage", {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
    });
  }

  it("recognizes iPhone, iPad and iPadOS as a touch Mac", async () => {
    stubBrowser(new Map());
    const { isIos } = await import("../install");
    expect(isIos("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", 5)).toBe(true);
    expect(isIos("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)", 5)).toBe(true);
    expect(isIos("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 5)).toBe(true);
    expect(isIos("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 0)).toBe(false);
    expect(isIos("Mozilla/5.0 (Linux; Android 15)", 5)).toBe(false);
  });

  it("remembers Not now for 30 days", async () => {
    const store = new Map<string, string>();
    stubBrowser(store);
    const { dismissInstall, installDismissed, INSTALL_DISMISS_DAYS } = await import("../install");
    const t0 = Date.UTC(2026, 10, 5);
    expect(installDismissed(t0)).toBe(false);
    dismissInstall(t0);
    expect(installDismissed(t0 + 86_400_000)).toBe(true);
    expect(installDismissed(t0 + INSTALL_DISMISS_DAYS * 86_400_000)).toBe(false);
  });

  it("queues the after-RSVP card once", async () => {
    const store = new Map<string, string>();
    stubBrowser(store);
    const m = await import("../install");
    expect(m.installAfterRsvpPending()).toBe(false);
    m.noteRsvpForInstall();
    expect(m.installAfterRsvpPending()).toBe(true);
    m.markInstallAfterRsvpShown();
    m.noteRsvpForInstall();
    expect(m.installAfterRsvpPending()).toBe(false);
  });

  it("survives storage that throws", async () => {
    vi.stubGlobal("window", {
      addEventListener: () => undefined,
      matchMedia: () => ({ matches: false, addEventListener: () => undefined }),
    });
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
    });
    const m = await import("../install");
    expect(m.installDismissed()).toBe(false);
    expect(() => m.dismissInstall()).not.toThrow();
    expect(m.installAfterRsvpPending()).toBe(false);
  });
});
