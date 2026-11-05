import type { Metadata } from "next";
import Link from "next/link";

import { APP_URL } from "@/lib/site";

export const metadata: Metadata = { title: "Page not found" };

/** The site's 404 (an unknown path, or a share link to a plan that is gone or private). */
export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col justify-center gap-6 px-4 py-16">
      <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
      <h1 className="text-4xl font-semibold tracking-tight">This page isn&rsquo;t here</h1>
      <p className="text-lg text-text-2">
        The link may be old, or the plan may have been cancelled or made private.
      </p>
      <ul className="flex flex-wrap gap-x-5 gap-y-2">
        <li>
          <Link href="/" className="font-semibold text-text underline-offset-2 hover:underline">
            Home
          </Link>
        </li>
        <li>
          <a href={APP_URL} className="font-semibold text-text underline-offset-2 hover:underline">
            Open the app
          </a>
        </li>
        <li>
          <Link
            href="/safety"
            className="font-semibold text-text underline-offset-2 hover:underline"
          >
            Safety Center
          </Link>
        </li>
      </ul>
    </main>
  );
}
