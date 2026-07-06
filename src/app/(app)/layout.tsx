import { redirect } from "next/navigation";

import { AppShell } from "@/components/shared/app-shell";
import { UserProvider } from "@/components/shared/user-provider";
import { createClient } from "@/lib/supabase/server";

/**
 * Gate for every internal app page: middleware already guarantees a session,
 * and this layout guarantees a completed profile. A signed-in user without a
 * profile row is always forced through onboarding.
 */
export default async function AppLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("id, email, username, organization, selected_hobbies")
    .eq("id", user.id)
    .maybeSingle();

  if (!profile) {
    redirect("/onboarding");
  }

  return (
    <UserProvider
      user={{
        id: profile.id,
        email: profile.email,
        username: profile.username,
        organization: profile.organization,
        selectedHobbies: profile.selected_hobbies,
      }}
    >
      <AppShell>{children}</AppShell>
    </UserProvider>
  );
}
