// Browse flows on an onboarded account, at 390x844 and 1280x800: Home feed sections and the
// "Also happening" shelf, the Hubs tab and a hub page, the Map tab's list panel (the basemap
// itself needs the tile host, which may be unreachable where this runs), Suggest a calendar.
// Usage: E2E_EMAIL=... E2E_PASSWORD=... node e2e/02-browse.mjs
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

const browser = await pw.chromium.launch();
let failed = 0;
for (const [vpName, viewport] of Object.entries(VIEWPORTS)) {
  const { page, problems } = await openContext(browser, viewport);
  const r = makeRunner(`browse-${vpName}`);
  const snap = (n) => shot(page, `browse-${vpName}-${n}`);

  await r.step("sign in to Home", async () => {
    await signIn(page, env.email, env.password);
    await page.getByRole("heading", { name: /^Hi, / }).waitFor({ timeout: 20000 });
  });

  await r.step("Home feed sections", async () => {
    // Wait for the skeletons to go.
    await page.waitForFunction(() => !document.querySelector('[aria-busy="true"]'), null, {
      timeout: 20000,
    });
    await page.waitForLoadState("networkidle");
    await snap("01-home");
    await assertNoHorizontalScroll(page, "home");
    const origin = await page.getByRole("button", { name: /^Showing plans/ }).textContent();
    if (/Near you/.test(origin ?? ""))
      throw new Error(`origin chip says "${origin}" for a saved city home`);
    const sections = await page.locator("main h3").allTextContents();
    console.log(`  sections: ${sections.join(" | ")}`);
    if (!sections.length) throw new Error("no feed sections or empty state headings");
  });

  await r.step("Also happening shelf", async () => {
    const shelf = page.getByRole("region", { name: "Also happening" });
    if ((await shelf.count()) === 0) {
      // Imported listings exist only where calendars are collected (Atlanta on staging).
      console.log("  NOTE: no Also happening shelf for this home (no imported listings here)");
      return;
    }
    await shelf.scrollIntoViewIfNeeded();
    await snap("02-also-happening");
    const more = shelf.getByRole("button", { name: /^Show more/ });
    if (await more.count()) {
      const before = await shelf.locator("article, a[href^='/events/']").count();
      await more.click();
      const after = await shelf.locator("article, a[href^='/events/']").count();
      if (after <= before) throw new Error("Show more did not add cards");
    }
  });

  await r.step("top bar Search button goes somewhere", async () => {
    await page.evaluate(() => window.scrollTo(0, 0));
    const before = page.url();
    await page
      .getByRole("link", { name: "Search hubs" })
      .or(page.getByRole("button", { name: "Search" }))
      .first()
      .click();
    await page.waitForTimeout(800);
    const dialog = await page.getByRole("dialog").count();
    if (page.url() === before && dialog === 0) throw new Error("Search does nothing (dead end)");
    await snap("03-search");
    await page.goto(`${env.base}/`);
    await page.getByRole("heading", { name: /^Hi, / }).waitFor({ timeout: 20000 });
  });

  await r.step("Hubs tab and a hub page", async () => {
    await page.goto(`${env.base}/hubs`);
    await page.waitForLoadState("networkidle");
    await snap("04-hubs");
    await assertNoHorizontalScroll(page, "hubs");
    const link = page.locator("a[href^='/hubs/']").first();
    await link.waitFor({ timeout: 15000 });
    await link.click();
    await page.waitForURL(/\/hubs\/[^/]+$/);
    await page.getByRole("heading", { name: "Members" }).waitFor({ timeout: 20000 });
    await snap("05-hub-page");
    await assertNoHorizontalScroll(page, "hub page");
  });

  await r.step("Map tab list panel", async () => {
    await page.goto(`${env.base}/map`);
    await page.waitForLoadState("networkidle").catch(() => undefined);
    await page.waitForTimeout(2500);
    await snap("06-map");
    await assertNoHorizontalScroll(page, "map");
    // The list panel: a button/tab to show the list on phones, always visible on desktop.
    const listToggle = page.getByRole("button", { name: /list/i }).first();
    if (await listToggle.count()) {
      await listToggle.click().catch(() => undefined);
      await page.waitForTimeout(1000);
    }
    await snap("07-map-list");
    const items = await page.locator("a[href^='/events/'], [role='listitem'], li").count();
    if (items === 0) {
      if (await page.getByText("We're mapping this area").count()) {
        console.log(
          "  NOTE: this area's places are not mapped yet; the list shows the mapping notice",
        );
        return;
      }
      throw new Error("map list panel shows no rows");
    }
  });

  await r.step("Suggest a calendar", async () => {
    await page.goto(`${env.base}/suggest-calendar`);
    await page.getByRole("heading").first().waitFor();
    await page.waitForLoadState("networkidle");
    await snap("08-suggest-calendar");
    await assertNoHorizontalScroll(page, "suggest calendar");
  });

  console.log(
    problems.length
      ? `PROBLEMS (${vpName}):\n  ${[...new Set(problems)].join("\n  ")}`
      : `PROBLEMS (${vpName}): none`,
  );
  failed += r.done();
  await page.context().close();
}
await browser.close();
process.exit(failed ? 1 : 0);
