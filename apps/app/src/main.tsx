import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { RouterProvider, createRouter } from "@tanstack/react-router";
import { QueryClientProvider } from "@tanstack/react-query";

import { routeTree } from "./routeTree.gen";
import { queryClient } from "./lib/query";
import { supabase } from "./lib/supabase";
import { sessionQuery } from "./lib/auth";
import { clearFeedLocation } from "./lib/location";
import { syncPushSubscription } from "./lib/push";
import { initTheme } from "./lib/theme";
// Captures beforeinstallprompt before any screen mounts (lib/install.ts).
import "./lib/install";
import { ScreenLoader } from "./components/ui/spinner";
import "./styles.css";

initTheme();

// A lazy chunk from an older build is gone after a deploy: reload once to pick up the new build.
// sessionStorage keeps a broken network from turning this into a reload loop.
window.addEventListener("vite:preloadError", (event) => {
  let reloaded: boolean;
  try {
    reloaded = sessionStorage.getItem("ap-preload-reload") === "1";
    if (!reloaded) sessionStorage.setItem("ap-preload-reload", "1");
  } catch {
    reloaded = true;
  }
  if (reloaded) return;
  event.preventDefault();
  window.location.reload();
});
// This load worked: a later deploy in the same tab may reload once again.
window.setTimeout(() => {
  try {
    sessionStorage.removeItem("ap-preload-reload");
  } catch {
    /* ignore */
  }
}, 10_000);

const router = createRouter({
  routeTree,
  context: { queryClient },
  defaultPreload: "intent",
  defaultPendingComponent: ScreenLoader,
  defaultPendingMs: 300,
  scrollRestoration: true,
});

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

// Keep the cached session in step with supabase-js and re-run route guards when it changes.
// Deferred with setTimeout: supabase-js warns against awaiting its own calls inside this callback.
supabase.auth.onAuthStateChange((event, session) => {
  queryClient.setQueryData(sessionQuery.queryKey, session);
  if (event === "SIGNED_OUT") {
    queryClient.removeQueries({ queryKey: ["profile"] });
    queryClient.removeQueries({ queryKey: ["my-hubs"] });
    queryClient.removeQueries({ queryKey: ["feed"] });
    queryClient.removeQueries({ queryKey: ["feed-prefs"] });
    // Map views can hold the previous person's own private and pending places (lib/map.ts).
    queryClient.removeQueries({ queryKey: ["map"] });
    clearFeedLocation();
  }
  // A push subscription the browser renewed is saved again for the person who turned push on.
  const userId = session?.user.id;
  if (userId && (event === "INITIAL_SESSION" || event === "SIGNED_IN")) {
    setTimeout(() => void syncPushSubscription(userId), 0);
  }
  setTimeout(() => void router.invalidate(), 0);
});

// The service worker says the subscription changed (pushsubscriptionchange).
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.addEventListener("message", (event: MessageEvent<unknown>) => {
    const data = event.data as { type?: unknown } | null;
    if (data?.type !== "push-subscription-changed") return;
    void supabase.auth.getSession().then(({ data: { session } }) => {
      if (session) void syncPushSubscription(session.user.id);
    });
  });
}

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Missing #root element");

createRoot(rootElement).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
);
