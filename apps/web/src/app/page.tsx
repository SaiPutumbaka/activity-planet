import { APP_URL } from "@/lib/site";

export default function LandingPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col justify-center gap-6 px-4 py-16">
      <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
      <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
        Find your people and something to do with them this week.
      </h1>
      <p className="text-lg text-text-2">
        Hubs for every interest, real plans and real people, wherever you live. Tell it where you
        are and it shows what&apos;s happening around you first: plans posted by people near you,
        plus public events from local calendars.
      </p>
      <p className="text-sm text-text-2">
        For adults 18 and over, anywhere. This page is being rebuilt; the full site arrives in the
        coming weeks.
      </p>
      <a
        href={APP_URL}
        className="inline-flex w-fit items-center rounded-full bg-primary px-5 py-3 text-base font-semibold text-on-primary"
      >
        Open the app
      </a>
    </main>
  );
}
