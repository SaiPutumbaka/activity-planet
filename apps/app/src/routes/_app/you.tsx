import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { toast } from "sonner";
import { AppIcon } from "@ap/ui/brand";

import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { authErrorMessage, signOut } from "@/lib/auth";
import { cn } from "@/lib/cn";
import { setThemePreference, useThemePreference, type ThemePreference } from "@/lib/theme";

const appRoute = getRouteApi("/_app");
const siteUrl =
  (import.meta.env.VITE_SITE_URL as string | undefined) ?? "https://activityplanet.app";

export const Route = createFileRoute("/_app/you")({
  component: YouPage,
});

const THEMES: { value: ThemePreference; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

function YouPage() {
  const { session, profile } = appRoute.useRouteContext();
  const theme = useThemePreference();
  const navigate = useNavigate();
  const [signingOut, setSigningOut] = useState(false);

  async function onSignOut() {
    setSigningOut(true);
    try {
      await signOut();
      await navigate({ to: "/auth/sign-in", replace: true });
    } catch (err) {
      toast.error(authErrorMessage(err));
      setSigningOut(false);
    }
  }

  return (
    <>
      <TopBar title="You" />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        <section className="flex items-center gap-4 pt-2">
          <div className="flex size-16 items-center justify-center rounded-full bg-primary-tint text-[24px] font-bold text-primary-text">
            {profile.first_name.slice(0, 1).toUpperCase()}
          </div>
          <div className="min-w-0">
            <p className="truncate text-[20px] font-extrabold tracking-tight">
              {profile.first_name}
            </p>
            <p className="truncate text-text-2">@{profile.handle}</p>
            <p className="truncate text-[13px] text-text-3">{session.user.email}</p>
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
            Appearance
          </h3>
          <div
            role="radiogroup"
            aria-label="Theme"
            className="flex rounded-control bg-surface-2 p-1"
          >
            {THEMES.map((t) => (
              <button
                key={t.value}
                type="button"
                role="radio"
                aria-checked={theme === t.value}
                onClick={() => setThemePreference(t.value)}
                className={cn(
                  "h-9 flex-1 rounded-control text-[14px] font-semibold transition-colors",
                  theme === t.value
                    ? "bg-surface text-text shadow-[var(--shadow-card)]"
                    : "text-text-2",
                )}
              >
                {t.label}
              </button>
            ))}
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">Account</h3>
          <div className="divide-y divide-border overflow-hidden rounded-card border border-border">
            <Row label="Email" value={session.user.email ?? ""} />
            <Row label="Handle" value={`@${profile.handle}`} hint="Changes once every 30 days" />
            <Row
              label="Campus space"
              value={profile.home_campus_id ? "Georgia State" : "Not set"}
              hint="Verify a .edu email to unlock it (coming soon)"
            />
          </div>
        </section>

        <section className="flex flex-col gap-3">
          <Button variant="secondary" block loading={signingOut} onClick={onSignOut}>
            Sign out
          </Button>
          <Link
            to="/you/delete"
            className="text-center text-[14px] font-medium text-text-2 underline-offset-2 hover:underline"
          >
            Delete my account
          </Link>
        </section>

        <footer className="flex flex-col items-center gap-2 pt-4 text-center text-[12px] text-text-3">
          <AppIcon size={40} />
          <p>Activity Planet · early build</p>
          <p>Not affiliated with or endorsed by Georgia State University.</p>
          <p className="flex gap-3">
            <a href={`${siteUrl}/terms`} className="underline-offset-2 hover:underline">
              Terms
            </a>
            <a href={`${siteUrl}/privacy`} className="underline-offset-2 hover:underline">
              Privacy
            </a>
            <a href={`${siteUrl}/safety`} className="underline-offset-2 hover:underline">
              Safety
            </a>
          </p>
        </footer>
      </main>
    </>
  );
}

function Row({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="flex items-center justify-between gap-4 px-4 py-3">
      <div className="min-w-0">
        <p className="text-[15px] font-medium">{label}</p>
        {hint ? <p className="text-[12px] text-text-3">{hint}</p> : null}
      </div>
      <p className="truncate text-[15px] text-text-2">{value}</p>
    </div>
  );
}
