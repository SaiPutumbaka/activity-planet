import { Outlet, createFileRoute } from "@tanstack/react-router";
import { Mark } from "@ap/ui/brand";

const siteUrl =
  (import.meta.env.VITE_SITE_URL as string | undefined) ?? "https://activityplanet.app";

/** Shared frame for every auth screen: the lockup on top, one column, legal links at the bottom. */
export const Route = createFileRoute("/auth")({
  component: AuthLayout,
});

function AuthLayout() {
  return (
    <div className="mx-auto flex min-h-dvh w-full max-w-sm flex-col safe-px safe-pt safe-pb">
      <header className="flex items-center gap-2 pt-10 pb-8">
        <Mark size={32} />
        <span className="text-[22px] font-extrabold tracking-[-0.03em]">Activity Planet</span>
      </header>
      <main className="flex flex-1 flex-col">
        <Outlet />
      </main>
      <footer className="flex flex-col items-center gap-1 py-6 text-center text-[12px] text-text-3">
        <p className="flex gap-3">
          <a href={`${siteUrl}/terms`} className="underline-offset-2 hover:underline">
            Terms
          </a>
          <a href={`${siteUrl}/privacy`} className="underline-offset-2 hover:underline">
            Privacy
          </a>
          <a href={`${siteUrl}/support`} className="underline-offset-2 hover:underline">
            Help
          </a>
        </p>
        <p>Not affiliated with or endorsed by Georgia State University.</p>
      </footer>
    </div>
  );
}
