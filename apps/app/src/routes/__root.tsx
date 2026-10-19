import {
  Link,
  Outlet,
  createRootRouteWithContext,
  type ErrorComponentProps,
} from "@tanstack/react-router";
import type { QueryClient } from "@tanstack/react-query";
import { Toaster } from "sonner";
import { Mark } from "@ap/ui/brand";

import { Button } from "@/components/ui/button";
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
  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col items-center justify-center gap-4 px-6 text-center">
      <Mark size={56} mono className="text-text-3" />
      <h1 className="text-[24px] font-bold tracking-tight">Something broke</h1>
      <p className="text-text-2">
        {error instanceof Error && error.message ? error.message : "Try again in a moment."}
      </p>
      <div className="flex gap-2">
        <Button variant="secondary" onClick={reset}>
          Try again
        </Button>
        <Link to="/">
          <Button variant="ghost">Go home</Button>
        </Link>
      </div>
    </main>
  );
}
