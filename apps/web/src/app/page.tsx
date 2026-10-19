const APP_URL = process.env.NEXT_PUBLIC_APP_URL ?? "https://app.activityplanet.app";

export default function LandingPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col justify-center gap-6 px-4 py-16">
      <p className="text-sm font-medium uppercase tracking-wide text-muted">Activity Planet</p>
      <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
        Find your people and something to do with them this week.
      </h1>
      <p className="text-lg text-muted">
        Hubs for every interest, real plans, real connection. Launching for Georgia State students
        in January 2027. This page is being rebuilt; the full site arrives in the coming weeks.
      </p>
      <p className="text-sm text-muted">
        Not affiliated with or endorsed by Georgia State University.
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
