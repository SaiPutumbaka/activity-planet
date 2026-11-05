import type { Metadata } from "next";

import { APP_URL } from "@/lib/site";

export const metadata: Metadata = {
  title: "Unsubscribe",
  description: "Stop notification emails from Activity Planet.",
  robots: { index: false, follow: false },
};

const TOKEN_RE = /^[0-9a-f-]{36}\.[0-9a-f]{64}$/;

/**
 * /unsubscribe?t=<token>: the link at the bottom of every notification email (migration 55).
 * Opening it changes nothing (mail scanners open links); the button posts to /api/unsubscribe,
 * which turns email off and comes back here with ?status=. Written for anyone (D-040).
 */
export default async function UnsubscribePage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const t = typeof params.t === "string" && TOKEN_RE.test(params.t) ? params.t : null;
  const status = typeof params.status === "string" ? params.status : null;

  let title = "Stop notification emails?";
  let body =
    "You'll stop getting emails about your plans, reminders and updates. Your inbox in the app keeps every notification, and push on your devices is unchanged.";
  if (status === "done") {
    title = "You're unsubscribed";
    body =
      "We won't send you notification emails anymore. You can turn them back on any time in the app under You, then Notifications.";
  } else if (status === "invalid" || (!status && !t)) {
    title = "This link doesn't work";
    body =
      "It may be incomplete or out of date. You can turn emails off in the app under You, then Notifications.";
  } else if (status === "error") {
    title = "Something went wrong";
    body = "We couldn't save that. Try the link in your email again in a few minutes.";
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-xl flex-col justify-center gap-6 px-4 py-16">
      <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
      <h1 className="text-3xl font-semibold tracking-tight">{title}</h1>
      <p className="text-text-2">{body}</p>
      {t && !status ? (
        <form method="post" action={`/api/unsubscribe?t=${encodeURIComponent(t)}`}>
          <button
            type="submit"
            className="inline-flex w-fit items-center rounded-full bg-primary px-5 py-3 text-base font-semibold text-on-primary"
          >
            Unsubscribe from emails
          </button>
        </form>
      ) : null}
      <a
        href={`${APP_URL}/you/notifications`}
        className="font-medium text-text underline underline-offset-2 hover:no-underline"
      >
        Open notification settings
      </a>
    </main>
  );
}
