import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Map data and licences",
  description:
    "Where the places on the Activity Planet map come from, who to credit, and how to download them as open data under the ODbL.",
};

const RELEASES_URL = "https://github.com/SaiPutumbaka/activity-planet/releases";

const link = "font-semibold text-text underline-offset-2 hover:underline";

/**
 * Public page for the hub map's licences (D-041, HUB_MAP_DESIGN section 8): the ODbL notice for
 * place facts, the credits for OpenStreetMap, Geoapify, OpenMapTiles and OpenFreeMap, and the
 * monthly download. Linked from the place card in the app and from the dump's README.
 */
export default function MapDataPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col gap-10 px-4 py-16">
      <header className="flex flex-col gap-4">
        <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">Map data and licences</h1>
        <p className="text-lg text-text-2">
          The places on our map are open data. Anyone can download them, use them and build on them,
          as long as they credit the sources and keep what they make open too.
        </p>
      </header>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">Where the places come from</h2>
        <ul className="list-disc space-y-2 pl-5 text-text-2">
          <li>
            <strong className="text-text">OpenStreetMap.</strong> Most places are from{" "}
            <a href="https://www.openstreetmap.org/copyright" className={link}>
              © OpenStreetMap contributors
            </a>
            , available under the Open Database License.
          </li>
          <li>
            <strong className="text-text">Geoapify.</strong> In some areas, places come from{" "}
            <a href="https://www.geoapify.com/" className={link}>
              Geoapify
            </a>
            , which is built on OpenStreetMap data. The map says &ldquo;Powered by Geoapify&rdquo;
            while those places are on screen.
          </li>
          <li>
            <strong className="text-text">Members.</strong> People who use Activity Planet add spots
            and correct details. Public additions are reviewed by a moderator before anyone else
            sees them.
          </li>
          <li>
            <strong className="text-text">Public plans.</strong> A public venue where public plans
            happen can show up as a meeting spot. Private addresses never do.
          </li>
        </ul>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">The licence</h2>
        <p className="text-text-2">
          The places database is made available under the{" "}
          <a href="https://opendatacommons.org/licenses/odbl/1-0/" className={link}>
            Open Database License (ODbL) 1.0
          </a>
          . When you add or correct a place&rsquo;s name, location, kind, opening hours or website,
          you agree that those facts are published under the same licence. Nothing about you, such
          as your name or account, is part of a place.
        </p>
        <p className="text-text-2">
          Spotted a mistake in a place from OpenStreetMap? Fix it at the source with &ldquo;Improve
          it on OpenStreetMap&rdquo; on the place card, so every map that uses OpenStreetMap gets
          the fix.
        </p>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">Download the places</h2>
        <p className="text-text-2">
          Every month we publish the public places as one file, with a README that lists the columns
          and sources. It holds names, kinds, points, opening hours and websites, and never ids,
          accounts, private pins or places waiting for review.
        </p>
        <a
          href={RELEASES_URL}
          className="inline-flex w-fit items-center rounded-full bg-primary px-5 py-3 text-base font-semibold text-on-primary"
        >
          Monthly releases
        </a>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">Map tiles</h2>
        <p className="text-text-2">
          The map itself is drawn from{" "}
          <a href="https://openfreemap.org/" className={link}>
            OpenFreeMap
          </a>{" "}
          tiles using the{" "}
          <a href="https://openmaptiles.org/" className={link}>
            OpenMapTiles
          </a>{" "}
          schema, from OpenStreetMap data. Your device loads those tiles straight from OpenFreeMap,
          which sees your IP address and the area you are looking at.
        </p>
      </section>
    </main>
  );
}
