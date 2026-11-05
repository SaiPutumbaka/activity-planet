import type { Json } from "@ap/core/types";

import { supabase } from "./supabase";

/**
 * Web push on this device (migration 55; PLAN.md 4.10). The browser asks for permission only
 * when the person taps "Turn on notifications" (never on load). The subscription is saved with
 * register_push_device (one live row per endpoint; a browser shared between accounts pushes only
 * for the one that turned it on last) and removed with unregister_push_device, which signOut()
 * also calls so a signed-out browser stops getting the previous person's pushes. The
 * send-notifications Edge Function does the sending; its VAPID public key is VITE_VAPID_PUBLIC_KEY.
 *
 *   pushState()               // "unsupported" | "needs_install" | "unconfigured" | "denied" | "off" | "on"
 *   await enablePush()        // on a tap only
 *   await disablePush()
 */

export type PushState = "unsupported" | "needs_install" | "unconfigured" | "denied" | "off" | "on";

export const VAPID_PUBLIC_KEY =
  (import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined)?.trim() || null;

/** base64url (the VAPID public key) to the bytes PushManager.subscribe wants. */
export function urlBase64ToUint8Array(value: string): Uint8Array<ArrayBuffer> {
  const clean = value.trim().replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  if (!/^[A-Za-z0-9+/]*$/.test(clean)) throw new Error("bad_key");
  const bin = atob(clean + "=".repeat((4 - (clean.length % 4)) % 4));
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

interface Env {
  hasServiceWorker: boolean;
  hasPushManager: boolean;
  hasNotification: boolean;
  permission: NotificationPermission | null;
  standalone: boolean;
  iOS: boolean;
  configured: boolean;
}

/**
 * What the device allows, before looking at the subscription. iPhone and iPad offer web push
 * only to an app added to the Home Screen, so a Safari tab there gets "needs_install".
 */
export function basePushState(env: Env): Exclude<PushState, "on"> | null {
  if (env.iOS && !env.standalone && !env.hasPushManager) return "needs_install";
  if (!env.hasServiceWorker || !env.hasPushManager || !env.hasNotification) {
    return env.iOS && !env.standalone ? "needs_install" : "unsupported";
  }
  if (!env.configured) return "unconfigured";
  if (env.permission === "denied") return "denied";
  return null;
}

function readEnv(): Env {
  const nav = typeof navigator === "undefined" ? null : navigator;
  const ua = nav?.userAgent ?? "";
  const iOS =
    /iPad|iPhone|iPod/.test(ua) || (/Macintosh/.test(ua) && (nav?.maxTouchPoints ?? 0) > 1);
  const standalone =
    typeof window !== "undefined" &&
    (window.matchMedia?.("(display-mode: standalone)").matches ||
      (nav as (Navigator & { standalone?: boolean }) | null)?.standalone === true);
  return {
    hasServiceWorker: !!nav && "serviceWorker" in nav,
    hasPushManager: typeof window !== "undefined" && "PushManager" in window,
    hasNotification: typeof Notification !== "undefined",
    permission: typeof Notification !== "undefined" ? Notification.permission : null,
    standalone,
    iOS,
    configured: VAPID_PUBLIC_KEY !== null,
  };
}

async function currentSubscription(): Promise<PushSubscription | null> {
  if (!("serviceWorker" in navigator)) return null;
  const reg = await navigator.serviceWorker.getRegistration();
  return (await reg?.pushManager.getSubscription()) ?? null;
}

/** The device's state for this person: "on" when this browser has a live row for them. */
export async function pushState(userId: string): Promise<PushState> {
  const base = basePushState(readEnv());
  if (base) return base;
  if (Notification.permission !== "granted") return "off";
  const sub = await currentSubscription();
  if (!sub) return "off";
  const { data, error } = await supabase
    .from("push_devices")
    .select("id")
    .eq("user_id", userId)
    .is("revoked_at", null)
    .eq("subscription->>endpoint", sub.endpoint)
    .limit(1);
  if (error) throw error;
  return data.length > 0 ? "on" : "off";
}

export class PushError extends Error {
  constructor(readonly code: "denied" | "unsupported" | "unconfigured" | "failed") {
    super(code);
  }
}

/** Asks for permission (call it from a tap), subscribes and saves the subscription. */
export async function enablePush(): Promise<void> {
  const base = basePushState(readEnv());
  if (base === "denied") throw new PushError("denied");
  if (base === "unconfigured") throw new PushError("unconfigured");
  if (base) throw new PushError("unsupported");
  const permission = await Notification.requestPermission();
  if (permission !== "granted") throw new PushError("denied");
  const reg = await navigator.serviceWorker.ready;
  const key = urlBase64ToUint8Array(VAPID_PUBLIC_KEY ?? "");
  let sub = await reg.pushManager.getSubscription();
  // A subscription made for another key cannot be used; replace it.
  const existingKey = sub?.options.applicationServerKey;
  if (sub && existingKey && !sameBytes(new Uint8Array(existingKey), key)) {
    await sub.unsubscribe().catch(() => undefined);
    sub = null;
  }
  sub ??= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  const { error } = await supabase.rpc("register_push_device", {
    p_subscription: sub.toJSON() as Json,
    p_user_agent: navigator.userAgent.slice(0, 300),
  });
  if (error) throw new PushError("failed");
}

/** Stops pushes to this browser for the signed-in person. Safe to call when nothing is set up. */
export async function disablePush(): Promise<void> {
  if (typeof navigator === "undefined" || !("serviceWorker" in navigator)) return;
  const sub = await currentSubscription().catch(() => null);
  if (!sub) return;
  await supabase.rpc("unregister_push_device", { p_endpoint: sub.endpoint }).then(
    () => undefined,
    () => undefined,
  );
  await sub.unsubscribe().catch(() => undefined);
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

export function pushErrorMessage(err: unknown): string {
  const code = err instanceof PushError ? err.code : "failed";
  switch (code) {
    case "denied":
      return "Notifications are blocked for this site. Allow them in your browser settings, then try again.";
    case "unsupported":
      return "This browser can't show notifications from Activity Planet.";
    case "unconfigured":
      return "Push isn't available yet. Email and the inbox still work.";
    default:
      return "Couldn't turn on notifications. Try again.";
  }
}
