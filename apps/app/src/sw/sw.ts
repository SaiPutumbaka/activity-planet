/// <reference lib="webworker" />
/**
 * The app's service worker (vite-plugin-pwa injectManifest, migration 55). It keeps everything the
 * generated worker did before (precache of the shell, the SPA navigation fallback, the runtime
 * caches for the map bundle, place tile files and fonts, auto-update) and adds web push: the
 * send-notifications Edge Function sends an encrypted JSON payload {title, body, url, tag, nid}
 * and this shows it; a tap focuses an open app window (or opens one) on the in-app path.
 *
 * Built by tsconfig.sw.json (WebWorker types), not the app's DOM tsconfig.
 */
import { clientsClaim } from "workbox-core";
import {
  cleanupOutdatedCaches,
  createHandlerBoundToURL,
  precacheAndRoute,
  type PrecacheEntry,
} from "workbox-precaching";
import { NavigationRoute, registerRoute } from "workbox-routing";
import { CacheFirst, StaleWhileRevalidate } from "workbox-strategies";
import { ExpirationPlugin } from "workbox-expiration";
import { CacheableResponsePlugin } from "workbox-cacheable-response";

import { parsePushPayload, safeAppPath } from "./push-payload";

declare const self: ServiceWorkerGlobalScope & { __WB_MANIFEST: (string | PrecacheEntry)[] };

// registerType "autoUpdate": a new worker takes over at once.
void self.skipWaiting();
clientsClaim();

precacheAndRoute(self.__WB_MANIFEST);
cleanupOutdatedCaches();

registerRoute(
  new NavigationRoute(createHandlerBoundToURL("/index.html"), { denylist: [/^\/api\//] }),
);

// MapLibre and its worker (lazy, Map tab only, D-038): cached on first use, never precached.
registerRoute(
  ({ url }) =>
    url.origin === self.location.origin &&
    /\/assets\/(map-canvas|maplibre-gl-worker)-/.test(url.pathname),
  new CacheFirst({ cacheName: "map-canvas", plugins: [new ExpirationPlugin({ maxEntries: 6 })] }),
);

// Static place tile files (D-042 slice 5): content-hashed names, so cache-first for 60 days.
registerRoute(
  ({ url }) =>
    /\/places\/v\d+\/\d+\.[0-9a-f]{16}\.json\.gz$|\/rules\/v\d+\.[0-9a-f]{16}\.json\.gz$/.test(
      url.pathname,
    ),
  new CacheFirst({
    cacheName: "place-files",
    plugins: [
      new ExpirationPlugin({ maxEntries: 60, maxAgeSeconds: 60 * 60 * 24 * 60 }),
      new CacheableResponsePlugin({ statuses: [200] }),
    ],
  }),
);

registerRoute(
  /^https:\/\/fonts\.googleapis\.com\/.*/i,
  new StaleWhileRevalidate({ cacheName: "google-fonts-stylesheets" }),
);
registerRoute(
  /^https:\/\/fonts\.gstatic\.com\/.*/i,
  new CacheFirst({
    cacheName: "google-fonts-webfonts",
    plugins: [new ExpirationPlugin({ maxEntries: 12, maxAgeSeconds: 60 * 60 * 24 * 365 })],
  }),
);

/* ------------------------------------------------------------------ */
/* Web push                                                             */
/* ------------------------------------------------------------------ */

self.addEventListener("push", (event) => {
  let raw: unknown;
  try {
    raw = event.data?.json() ?? null;
  } catch {
    raw = null;
  }
  const p = parsePushPayload(raw);
  event.waitUntil(
    self.registration.showNotification(p.title, {
      body: p.body,
      tag: p.tag,
      icon: "/icons/icon-192.png",
      badge: "/icons/icon-192.png",
      data: { url: p.url },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const data = event.notification.data as { url?: unknown } | null;
  const target = new URL(safeAppPath(data?.url), self.location.origin).href;
  event.waitUntil(
    (async () => {
      const windows = (await self.clients.matchAll({
        type: "window",
        includeUncontrolled: true,
      })) as readonly WindowClient[];
      for (const w of windows) {
        if (new URL(w.url).origin === self.location.origin) {
          await w.focus();
          await w.navigate(target).catch(() => undefined);
          return;
        }
      }
      await self.clients.openWindow(target);
    })(),
  );
});

// The browser rotated (or dropped) the subscription. The worker holds no session, so it only
// makes sure a new subscription exists (same options) and tells open pages; lib/push.ts
// syncPushSubscription saves it with register_push_device then, or on the app's next start.
interface PushSubscriptionChange extends ExtendableEvent {
  readonly oldSubscription?: PushSubscription | null;
  readonly newSubscription?: PushSubscription | null;
}
self.addEventListener("pushsubscriptionchange", (event) => {
  const change = event as PushSubscriptionChange;
  change.waitUntil(
    (async () => {
      let sub = change.newSubscription ?? (await self.registration.pushManager.getSubscription());
      const options = change.oldSubscription?.options;
      if (!sub && options?.applicationServerKey) {
        sub = await self.registration.pushManager
          .subscribe({ userVisibleOnly: true, applicationServerKey: options.applicationServerKey })
          .catch(() => null);
      }
      if (!sub) return;
      const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      for (const w of windows) w.postMessage({ type: "push-subscription-changed" });
    })(),
  );
});
