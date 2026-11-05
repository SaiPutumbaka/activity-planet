// Layout and console sweep: every main route at 390x844 and 1280x800, signed out and signed in,
// failing on a sideways scroll, a page error or an "Something broke" screen, and listing console
// errors and failed requests. Screenshots: sweep-<viewport>-<route>.png in E2E_QA_DIR.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  env,
  skipUnless,
  loadPlaywright,
  openContext,
  shot,
  signIn,
  makeRunner,
  assertNoHorizontalScroll,
  VIEWPORTS,
} from "./lib.mjs";

skipUnless(env.email && env.password, "E2E_EMAIL and E2E_PASSWORD are not set");
const pw = loadPlaywright();
skipUnless(pw, "playwright is not installed");
const idFile = join(env.outDir, "event-id.txt");
const eventId =
  process.env.E2E_EVENT_ID || (existsSync(idFile) ? readFileSync(idFile, "utf8").trim() : "");

const signedOut = ["/auth/sign-in", "/auth/sign-up", "/auth/forgot", "/map"];
const signedIn = [
  "/",
  "/hubs",
  "/hubs/airsoft",
  "/map",
  "/post",
  "/inbox",
  "/chats",
  "/you",
  "/you/notifications",
  "/you/blocked",
  "/you/delete",
  "/you/met",
  "/you/photo",
  "/you/verify",
  "/suggest-calendar",
  "/organizer",
  "/organizer/claim",
  "/coaches",
  "/coach",
  "/coach/profile",
  "/coach/availability",
  "/coach/listings/new",
  "/bookings",
  "/no-such-page",
  ...(eventId ? [`/events/${eventId}`, `/events/${eventId}/edit`] : []),
];

const browser = await pw.chromium.launch();
let failed = 0;
for (const [vpName, viewport] of Object.entries(VIEWPORTS)) {
  const { context, page, problems } = await openContext(browser, viewport);
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e.message)));
  const r = makeRunner(`sweep-${vpName}`);
  const visit = async (path, tag) => {
    await r.step(`${tag} ${path}`, async () => {
      errors.length = 0;
      await page.goto(`${env.base}${path}`);
      await page.waitForLoadState("networkidle").catch(() => undefined);
      await page.waitForTimeout(1500);
      await shot(page, `sweep-${vpName}-${tag}${path.replace(/[^a-z0-9]+/gi, "_")}`);
      await assertNoHorizontalScroll(page, path);
      if (await page.getByRole("heading", { name: "Something broke" }).count())
        throw new Error("error screen");
      if (errors.length) throw new Error(`page error: ${errors[0].slice(0, 200)}`);
    });
  };
  for (const p of signedOut) await visit(p, "out");
  await r.step("sign in", () => signIn(page, env.email, env.password));
  for (const p of signedIn) await visit(p, "in");
  console.log(
    problems.length
      ? `PROBLEMS (${vpName}):\n  ${[...new Set(problems)].join("\n  ")}`
      : `PROBLEMS (${vpName}): none`,
  );
  failed += r.done();
  await context.close();
}
await browser.close();
process.exit(failed ? 1 : 0);
