import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { RouterProvider, createRouter } from "@tanstack/react-router";
import { QueryClientProvider } from "@tanstack/react-query";

import { routeTree } from "./routeTree.gen";
import { queryClient } from "./lib/query";
import { supabase } from "./lib/supabase";
import { sessionQuery } from "./lib/auth";
import { initTheme } from "./lib/theme";
import { ScreenLoader } from "./components/ui/spinner";
import "./styles.css";

initTheme();

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
  }
  setTimeout(() => void router.invalidate(), 0);
});

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Missing #root element");

createRoot(rootElement).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
);
