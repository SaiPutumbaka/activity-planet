import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { ChevronRight } from "lucide-react";
import { toast } from "sonner";
import { AppIcon } from "@ap/ui/brand";

import { LocationSheet } from "@/components/feed/location-sheet";
import { TopBar } from "@/components/shell/top-bar";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { SegmentedControl } from "@/components/ui/segmented";
import { Skeleton } from "@/components/ui/skeleton";
import { ButtonRow, LinkRow } from "@/components/you/link-row";
import { authErrorMessage, signOut } from "@/lib/auth";
import { isModeratorQuery, myManagedChaptersQuery, roleLabel } from "@/lib/chapters";
import { feedPrefsQuery, useFeedOrigin } from "@/lib/location";
import { notificationPrefsQuery } from "@/lib/notifications";
import { profileQuery } from "@/lib/profile";
import { SITE_URL } from "@/lib/site";
import { setThemePreference, useThemePreference, type ThemePreference } from "@/lib/theme";
import { membershipQuery } from "@/lib/verification";

const appRoute = getRouteApi("/_app");
export const Route = createFileRoute("/_app/you")({
  component: YouPage,
});

const THEMES: { value: ThemePreference; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

function YouPage() {
  const { session, profile: contextProfile } = appRoute.useRouteContext();
  const theme = useThemePreference();
  const navigate = useNavigate();
  const [signingOut, setSigningOut] = useState(false);
  const [areaSheetOpen, setAreaSheetOpen] = useState(false);
  const origin = useFeedOrigin(session.user.id);
  const radius = useQuery(feedPrefsQuery(session.user.id));
  const radiusKm = radius.data?.radiusKm ?? 10;

  // The route context is a snapshot from beforeLoad; the photo and verify screens update the
  // query, so read from it (the cache is always warm here).
  const profileResult = useQuery(profileQuery(session.user.id));
  const profile = profileResult.data ?? contextProfile;
  const membership = useQuery(membershipQuery(session.user.id));
  const managed = useQuery(myManagedChaptersQuery(session.user.id));
  const isMod = useQuery(isModeratorQuery(session.user.id));
  const prefs = useQuery(notificationPrefsQuery(session.user.id));
  const chapters = managed.data ?? [];
  const verifiedSpace = membership.data
    ? (membership.data.org_campuses?.name ?? membership.data.organizations?.name ?? "Verified")
    : null;

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
          {/* key: Avatar remembers a broken image until it remounts. */}
          <Avatar
            key={profile.avatar_url ?? "none"}
            src={profile.avatar_url}
            name={profile.first_name}
            size={64}
          />
          <div className="min-w-0">
            <p className="truncate text-[20px] font-extrabold tracking-tight">
              {profile.first_name}
            </p>
            <p className="truncate text-text-2">@{profile.handle}</p>
            <p className="truncate text-[13px] text-text-3">{session.user.email}</p>
            <Link
              to="/you/photo"
              className="-my-2 inline-flex min-h-11 items-center text-[14px] font-semibold text-primary-text"
            >
              {profile.avatar_url ? "Change photo" : "Add photo"}
            </Link>
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
            Appearance
          </h3>
          <SegmentedControl
            value={theme}
            onChange={setThemePreference}
            options={THEMES}
            label="Theme"
          />
        </section>

        <section className="flex flex-col gap-2">
          <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">Account</h3>
          <div className="divide-y divide-border overflow-hidden rounded-card border border-border">
            <Row label="Email" value={session.user.email ?? ""} />
            <Row label="Handle" value={`@${profile.handle}`} hint="Changes once every 30 days" />
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
            Notifications
          </h3>
          <div className="divide-y divide-border overflow-hidden rounded-card border border-border">
            <LinkRow
              to="/you/notifications"
              label="Notification settings"
              hint="Reminders, plan changes, quiet hours"
              value={
                prefs.isPending ? (
                  <Skeleton className="h-4 w-12" />
                ) : prefs.data?.unsubscribed_all_at ? (
                  "Paused"
                ) : (
                  "On"
                )
              }
            />
            <LinkRow to="/inbox" label="Inbox" value="Open" />
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
            Your location
          </h3>
          <div className="divide-y divide-border overflow-hidden rounded-card border border-border">
            <ButtonRow
              label="Home location"
              hint="Home shows plans around here first. Not shown on your profile."
              value={
                radius.isPending ? (
                  <Skeleton className="h-4 w-20" />
                ) : (
                  (origin.homeLabel ?? (origin.homePoint ? "Your location" : "Not set"))
                )
              }
              onClick={() => setAreaSheetOpen(true)}
            />
            <ButtonRow
              label="Distance"
              hint="How far out Home looks"
              value={radius.isPending ? <Skeleton className="h-4 w-12" /> : `${radiusKm} km`}
              onClick={() => setAreaSheetOpen(true)}
            />
          </div>
        </section>

        <section className="flex flex-col gap-2">
          <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
            Affiliation
          </h3>
          <div className="divide-y divide-border overflow-hidden rounded-card border border-border">
            <LinkRow
              to="/you/verify"
              label="Verified affiliation (optional)"
              value={
                membership.isPending ? (
                  <Skeleton className="h-4 w-24" />
                ) : membership.isError ? (
                  "Couldn't check"
                ) : (
                  (verifiedSpace ?? "Not verified")
                )
              }
              valueClassName={verifiedSpace ? "font-semibold text-going" : undefined}
              hint={
                membership.isError
                  ? "Try again in a moment"
                  : verifiedSpace
                    ? "Verified with your school email"
                    : "Student, staff or alum? If your school has a campus space, verify your school email"
              }
            />
          </div>
        </section>

        {chapters.length > 0 || isMod.data ? (
          <section className="flex flex-col gap-2">
            <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
              Your chapters
            </h3>
            <div className="divide-y divide-border overflow-hidden rounded-card border border-border">
              {chapters.map((c) => (
                <Link
                  key={c.id}
                  to="/chapters/$slug"
                  params={{ slug: c.slug }}
                  className="flex min-h-11 items-center justify-between gap-4 px-4 py-3 transition-colors hover:bg-surface-2"
                >
                  <span className="min-w-0">
                    <span className="block truncate text-[15px] font-medium">{c.name}</span>
                    {c.placeLabel ? (
                      <span className="block truncate text-[12px] text-text-3">{c.placeLabel}</span>
                    ) : null}
                  </span>
                  <span className="flex shrink-0 items-center gap-1 text-[15px] text-text-2">
                    {roleLabel(c.role)}
                    <ChevronRight className="size-4 shrink-0 text-text-3" aria-hidden="true" />
                  </span>
                </Link>
              ))}
              {isMod.data ? (
                <LinkRow
                  to="/admin/claims"
                  label="Chapter claims"
                  value="Review"
                  hint="Moderators approve who runs a chapter"
                />
              ) : null}
            </div>
          </section>
        ) : null}

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
          <p className="flex gap-3">
            <a href={`${SITE_URL}/terms`} className="underline-offset-2 hover:underline">
              Terms
            </a>
            <a href={`${SITE_URL}/privacy`} className="underline-offset-2 hover:underline">
              Privacy
            </a>
            <a href={`${SITE_URL}/safety`} className="underline-offset-2 hover:underline">
              Safety
            </a>
          </p>
        </footer>
      </main>
      <LocationSheet
        open={areaSheetOpen}
        onClose={() => setAreaSheetOpen(false)}
        userId={session.user.id}
        origin={origin}
        radiusKm={radiusKm}
        showDevice={false}
      />
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
