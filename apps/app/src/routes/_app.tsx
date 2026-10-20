import { Outlet, createFileRoute, redirect } from "@tanstack/react-router";

import { TabBar } from "@/components/shell/tab-bar";
import { getSession } from "@/lib/auth";
import { getProfile } from "@/lib/profile";
import { supabase } from "@/lib/supabase";

/**
 * Everything behind the tab bar. Requires a session and a completed onboarding; both checks read
 * from the query cache, so the redirect decision is instant after the first load.
 */
export const Route = createFileRoute("/_app")({
  beforeLoad: async ({ context: { queryClient }, location }) => {
    const session = await getSession(queryClient);
    if (!session) {
      throw redirect({
        to: "/auth/sign-in",
        search: { next: location.href === "/" ? undefined : location.href },
        replace: true,
      });
    }
    const profile = await getProfile(queryClient, session.user.id);
    if (profile.deleted_at) {
      // The account was deleted but this device still holds a token (valid for up to an hour
      // after request_account_deletion banned the user). Drop it and start over.
      await supabase.auth.signOut({ scope: "local" });
      throw redirect({ to: "/auth/sign-in", replace: true });
    }
    if (!profile.onboarding_completed_at) {
      throw redirect({ to: "/onboarding", replace: true });
    }
    return { session, profile };
  },
  component: AppShell,
});

function AppShell() {
  return (
    <div className="mx-auto min-h-dvh max-w-lg pb-[calc(3.5rem+env(safe-area-inset-bottom,0px))]">
      <Outlet />
      <TabBar />
    </div>
  );
}
