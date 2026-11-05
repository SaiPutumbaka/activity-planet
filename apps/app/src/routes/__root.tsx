import {
  Link,
  Outlet,
  createRootRouteWithContext,
  useRouter,
  type ErrorComponentProps,
} from "@tanstack/react-router";
import { useCallback } from "react";
import type { QueryClient } from "@tanstack/react-query";
import { Toaster } from "sonner";
import { Mark } from "@ap/ui/brand";

import { Button } from "@/components/ui/button";
import { routeErrorCopy, useOnReconnect, useOnline } from "@/lib/online";
import { useResolvedTheme } from "@/lib/theme";

interface RouterContext {
  queryClient: QueryClient;
}

export const Route = createRootRouteWithContext<RouterContext>()({
  component: RootLayout,
  notFoundComponent: NotFound,
  errorComponent: RouteError,
});

function RootLayout() {
  const theme = useResolvedTheme();
  return (
    <>
      <Outlet />
      <Toaster
        position="top-center"
        theme={theme}
        closeButton
        toastOptions={{ style: { fontFamily: "var(--font-sans)" } }}
      />
    </>
  );
}

function NotFound() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col items-center justify-center gap-4 px-6 text-center">
      <Mark size={56} />
      <h1 className="text-[24px] font-bold tracking-tight">Nothing here</h1>
      <p className="text-text-2">That page doesn't exist, or it moved.</p>
      <Link to="/">
        <Button variant="secondary">Go home</Button>
      </Link>
    </main>
  );
}

function RouteError({ error, reset }: ErrorComponentProps) {
  const router = useRouter();
  const online = useOnline();
  const copy = routeErrorCopy(error, online);
  // reset() alone clears the boundary but keeps the failed load; invalidate re-runs the guards.
  const retry = useCallback(() => {
    reset();
    void router.invalidate();
  }, [reset, router]);
  // Back online: load the screen again without a tap.
  useOnReconnect(retry);
  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col items-center justify-center gap-4 px-6 text-center">
      <Mark size={56} mono className="text-text-3" />
      <h1 className="text-[24px] font-bold tracking-tight">{copy.title}</h1>
      <p className="text-text-2">{copy.body}</p>
      <div className="flex gap-2">
        <Button variant="secondary" onClick={retry}>
          Try again
        </Button>
        {copy.offline ? null : (
          <Link to="/">
            <Button variant="ghost">Go home</Button>
          </Link>
        )}
      </div>
    </main>
  );
}
