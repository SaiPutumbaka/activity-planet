import { Outlet, createFileRoute, redirect } from "@tanstack/react-router";

import { AppBadge } from "@/components/shell/app-badge";
import { TabBar } from "@/components/shell/tab-bar";
import { getSession } from "@/lib/auth";
import { ChatsRealtime } from "@/lib/messaging";
import { clearFeedLocation } from "@/lib/location";
import { OfflineError, isOnline } from "@/lib/online";
import { getProfile, profileQuery } from "@/lib/profile";
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
    // Offline with nothing cached: React Query would pause the profile fetch until the device is
    // back, leaving a spinner forever; fail now so the error screen says "You're offline".
    if (!isOnline() && queryClient.getQueryData(profileQuery(session.user.id).queryKey) == null) {
      throw new OfflineError();
    }
    // The own profile row is always readable (migration 22 keeps it out of the 18+ read gate),
    // so a missing row means the account is gone, not that RLS hid it.
    const profile = await getProfile(queryClient, session.user.id).catch((err: unknown) => {
      if (typeof err === "object" && err && "code" in err && err.code === "PGRST116") return null;
      throw err;
    });
    if (!profile || profile.deleted_at || profile.status === "deleted") {
      // The account was deleted but this device still holds a token (valid for up to an hour
      // after request_account_deletion banned the user). Drop it and start over. Everything
      // else would read empty anyway: other people's rows need an active, onboarded adult.
      await supabase.auth.signOut({ scope: "local" });
      clearFeedLocation();
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
  const { session } = Route.useRouteContext();
  return (
    <div className="mx-auto min-h-dvh max-w-lg pb-[calc(3.5rem+env(safe-area-inset-bottom,0px))]">
      <ChatsRealtime userId={session.user.id} />
      <AppBadge userId={session.user.id} />
      <Outlet />
      <TabBar />
    </div>
  );
}
