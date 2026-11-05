import { describe, expect, it, vi } from "vitest";

vi.mock("../supabase", () => ({ supabase: {} }));

import {
  basePushState,
  pushErrorMessage,
  PushError,
  pushSyncAction,
  urlBase64ToUint8Array,
} from "../push";
import { parsePushPayload, safeAppPath } from "../../sw/push-payload";

const env = {
  hasServiceWorker: true,
  hasPushManager: true,
  hasNotification: true,
  permission: "default" as NotificationPermission,
  standalone: false,
  iOS: false,
  configured: true,
};

describe("basePushState", () => {
  it("is open on a capable, configured browser", () => {
    expect(basePushState(env)).toBeNull();
  });
  it("asks iPhone Safari tabs to add to the Home Screen first", () => {
    expect(basePushState({ ...env, iOS: true, hasPushManager: false })).toBe("needs_install");
    expect(basePushState({ ...env, iOS: true, standalone: true })).toBeNull();
  });
  it("reports unsupported, unconfigured and denied", () => {
    expect(basePushState({ ...env, hasServiceWorker: false })).toBe("unsupported");
    expect(basePushState({ ...env, configured: false })).toBe("unconfigured");
    expect(basePushState({ ...env, permission: "denied" })).toBe("denied");
  });
});

describe("urlBase64ToUint8Array", () => {
  it("decodes base64url without padding", () => {
    expect(Array.from(urlBase64ToUint8Array("AQID_-8"))).toEqual([1, 2, 3, 255, 239]);
  });
  it("refuses other characters", () => {
    expect(() => urlBase64ToUint8Array("a b")).toThrow();
  });
});

describe("push payload in the service worker", () => {
  it("keeps in-app paths and sends anything else to the inbox", () => {
    expect(safeAppPath("/events/11111111-2222-4333-8444-555555555555")).toBe(
      "/events/11111111-2222-4333-8444-555555555555",
    );
    expect(safeAppPath("https://evil.example.com/")).toBe("/inbox");
    expect(safeAppPath("//evil.example.com/")).toBe("/inbox");
    expect(safeAppPath("javascript:alert(1)")).toBe("/inbox");
    expect(safeAppPath(42)).toBe("/inbox");
  });
  it("falls back to a title and trims long text", () => {
    const p = parsePushPayload({ body: "x".repeat(500), url: "/inbox", tag: "t" });
    expect(p.title).toBe("Activity Planet");
    expect(p.body).toHaveLength(180);
    expect(p.tag).toBe("t");
    expect(parsePushPayload(null)).toEqual({
      title: "Activity Planet",
      body: "",
      url: "/inbox",
      tag: undefined,
    });
  });
});

describe("copy", () => {
  it("assumes no audience or city (D-040)", () => {
    for (const code of ["denied", "unsupported", "unconfigured", "failed"] as const) {
      expect(pushErrorMessage(new PushError(code))).not.toMatch(/student|campus|atlanta|gsu/i);
    }
  });
});

describe("pushSyncAction", () => {
  it("saves a renewed subscription again for the person who turned push on", () => {
    expect(pushSyncAction("u1", "u1", false)).toBe("register");
    expect(pushSyncAction("u1", "u1", true)).toBe("none");
  });
  it("never registers someone else's browser for the person signed in now", () => {
    expect(pushSyncAction("u1", "u2", false)).toBe("none");
    expect(pushSyncAction("u1", "u2", true)).toBe("none");
    expect(pushSyncAction(null, "u2", false)).toBe("none");
  });
  it("adopts a live row from before the owner was remembered", () => {
    expect(pushSyncAction(null, "u1", true)).toBe("adopt");
  });
});
