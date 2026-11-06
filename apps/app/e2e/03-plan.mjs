// Plans: A posts a plan (as a member; as a chapter too when A manages one), the event page
// (Add to calendar, Share), then B goes and leaves. B joins the same hub as A first if needed.
// Usage: E2E_EMAIL/E2E_PASSWORD (host) E2E_EMAIL_B/E2E_PASSWORD_B (guest) node e2e/03-plan.mjs
import { writeFileSync } from "node:fs";
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
  MAIN_VIEWPORT,
} from "./lib.mjs";

skipUnless(
  env.email && env.password && env.emailB && env.passwordB,
  "E2E_EMAIL/_B and E2E_PASSWORD/_B are not set",
);
const pw = loadPlaywright();
skipUnless(pw, "playwright is not installed");

const browser = await pw.chromium.launch();
let failed = 0;
let eventId = null;
const title = `QA e2e plan ${new Date().toISOString().slice(0, 16)}`;

async function acceptGuidelinesIfAsked(page) {
  const agree = page.getByRole("button", { name: "I agree" });
  if (await agree.isVisible().catch(() => false)) await agree.click();
}

/* Host */
{
  const { context, page, problems } = await openContext(browser, MAIN_VIEWPORT);
  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: env.base });
  const r = makeRunner("plan-host");
  await r.step("sign in", () => signIn(page, env.email, env.password));

  await r.step("post a plan as a member", async () => {
    await page.goto(`${env.base}/post`);
    await page.getByLabel("Title").waitFor({ timeout: 20000 });
    await assertNoHorizontalScroll(page, "post");
    await page.getByLabel("Title").fill(title);
    await page
      .getByRole("radio", { name: "Describe" })
      .or(page.getByRole("tab", { name: "Describe" }))
      .or(page.getByRole("button", { name: "Describe" }))
      .first()
      .click();
    await page.getByLabel("Where to meet").fill("By the big oak at the park entrance");
    await shot(page, "plan-01-post-form");
    await page.getByRole("button", { name: "Post plan" }).click();
    await page.waitForTimeout(800);
    await acceptGuidelinesIfAsked(page);
    await page.waitForURL(/\/events\/[0-9a-f-]{36}$/, { timeout: 20000 });
    eventId = new URL(page.url()).pathname.split("/").pop();
    writeFileSync(join(env.outDir, "event-id.txt"), eventId);
    await page.getByRole("heading", { name: title }).waitFor();
    await page.getByText("You're hosting").waitFor();
    await shot(page, "plan-02-event-host");
    await assertNoHorizontalScroll(page, "event page");
  });

  await r.step("post as a chapter (when one is managed)", async () => {
    await page.goto(`${env.base}/post`);
    await page.getByLabel("Title").waitFor({ timeout: 20000 });
    const postAs = page.getByLabel("Post as");
    if ((await postAs.count()) === 0) {
      console.log("  NOTE: no managed chapter on this account; posting as a chapter not exercised");
      return;
    }
    throw new Error("chapter posting not scripted yet");
  });

  await r.step("event page: Add to calendar and Share", async () => {
    await page.goto(`${env.base}/events/${eventId}`);
    await page.getByRole("heading", { name: title }).waitFor({ timeout: 20000 });
    const add = page.getByRole("button", { name: "Add to calendar" });
    // Shown once the viewer's own RSVP has loaded.
    await add.waitFor({ timeout: 15000 }).catch(() => {
      throw new Error("host has no Add to calendar");
    });
    const [download] = await Promise.all([page.waitForEvent("download"), add.click()]);
    if (!download.suggestedFilename().endsWith(".ics"))
      throw new Error(`calendar file is ${download.suggestedFilename()}`);
    const g = await page.getByRole("link", { name: "Google Calendar" }).getAttribute("href");
    if (!g?.startsWith("https://calendar.google.com/"))
      throw new Error("Google Calendar link missing");
    await page.getByRole("button", { name: "Share" }).click();
    await page.getByText(/Link copied|Couldn't copy/).waitFor({ timeout: 5000 });
    const copied = await page.evaluate(() => navigator.clipboard.readText()).catch(() => "");
    if (!copied.includes(`/e/${eventId}`))
      throw new Error(`copied link is wrong: ${copied.replace(/[0-9a-f-]{36}/, "<id>")}`);
    await shot(page, "plan-03-shared");
  });

  await r.step("event page at desktop width", async () => {
    await page.setViewportSize(VIEWPORTS.desktop);
    await page.reload();
    await page.getByRole("heading", { name: title }).waitFor({ timeout: 20000 });
    await shot(page, "plan-04-event-desktop");
    await assertNoHorizontalScroll(page, "event page desktop");
  });

  console.log(
    problems.length
      ? `PROBLEMS (host):\n  ${[...new Set(problems)].join("\n  ")}`
      : "PROBLEMS (host): none",
  );
  failed += r.done();
  await context.close();
}

/* Guest */
if (eventId) {
  const { context, page, problems } = await openContext(browser, MAIN_VIEWPORT);
  const r = makeRunner("plan-guest");
  await r.step("sign in", () => signIn(page, env.emailB, env.passwordB));
  await r.step("RSVP going", async () => {
    await page.goto(`${env.base}/events/${eventId}`);
    await page.getByRole("heading", { name: title }).waitFor({ timeout: 20000 });
    await shot(page, "plan-05-guest-before");
    await page.getByRole("button", { name: "Going", exact: true }).click();
    await page.waitForTimeout(800);
    await acceptGuidelinesIfAsked(page);
    await page.getByText("You're going").first().waitFor({ timeout: 10000 });
    await page.getByRole("button", { name: "Add to calendar" }).waitFor();
    await shot(page, "plan-06-guest-going");
  });
  await r.step("leave the plan", async () => {
    await page.getByRole("button", { name: "More" }).click();
    await shot(page, "plan-07-guest-more");
    await page.getByRole("button", { name: "Leave this plan" }).click();
    await page.getByRole("button", { name: "Going", exact: true }).waitFor({ timeout: 10000 });
    await shot(page, "plan-08-guest-left");
  });
  console.log(
    problems.length
      ? `PROBLEMS (guest):\n  ${[...new Set(problems)].join("\n  ")}`
      : "PROBLEMS (guest): none",
  );
  failed += r.done();
  await context.close();
}
await browser.close();
process.exit(failed ? 1 : 0);
