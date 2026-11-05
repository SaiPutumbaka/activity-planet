// The public site (apps/web, `next build` + `next start`) at 390x844 and 1280x800: the landing
// page, /bot and its removal form, the Safety Center and intimate-image page, the policy pages
// (Terms, Privacy, Community Guidelines, Coach Terms, Refund Policy, map data; all drafts with
// the attorney banner), /account/delete, /unsubscribe and /support (the app's sign-in footer
// links it as Help).
// Each must answer 200, fit without a sideways scroll, give every image alt text and link only
// to pages that exist on the site. The site's 404 must offer a way home. No account is needed.
// Usage: E2E_SITE_URL=http://localhost:3000 node e2e/11-site.mjs
import {
  env,
  skipUnless,
  loadPlaywright,
  openContext,
  shot,
  makeRunner,
  assertNoHorizontalScroll,
  VIEWPORTS,
} from "./lib.mjs";

const site = (process.env.E2E_SITE_URL || "").replace(/\/+$/, "");
skipUnless(site, "E2E_SITE_URL is not set");
const pw = loadPlaywright();
skipUnless(pw, "playwright is not installed");

const PAGES = [
  "/",
  "/bot",
  "/bot/remove",
  "/safety",
  "/safety/intimate-images",
  "/terms",
  "/privacy",
  "/guidelines",
  "/coach-terms",
  "/refund-policy",
  "/map-data",
  "/account/delete",
  "/unsubscribe",
  "/support",
];
/** The policy drafts, which must carry the attorney banner until the reviewed texts replace them. */
const DRAFTS = new Set(["/terms", "/privacy", "/guidelines", "/coach-terms", "/refund-policy"]);

const browser = await pw.chromium.launch();
let failed = 0;
for (const [vpName, viewport] of Object.entries(VIEWPORTS)) {
  const { context, page } = await openContext(browser, viewport);
  const r = makeRunner(`site-${vpName}`);
  const linked = new Set();

  for (const path of PAGES) {
    await r.step(`${path} renders and fits`, async () => {
      const res = await page.goto(`${site}${path}`, { waitUntil: "networkidle" });
      if (!res || res.status() !== 200) throw new Error(`status ${res?.status()}`);
      await page.getByRole("heading", { level: 1 }).first().waitFor();
      if (DRAFTS.has(path) && !(await page.getByText(/^DRAFT:/).count()))
        throw new Error("no draft banner");
      await assertNoHorizontalScroll(page, path);
      const noAlt = await page.$$eval("img:not([alt])", (x) => x.length);
      if (noAlt) throw new Error(`${noAlt} image(s) without alt`);
      for (const href of await page.$$eval("a[href^='/']", (as) =>
        as.map((a) => a.getAttribute("href")),
      ))
        if (!href.startsWith("/e/")) linked.add(href.split("#")[0].split("?")[0]);
      await shot(page, `site-${vpName}-${path.replace(/\W+/g, "_") || "root"}`);
    });
  }

  await r.step("every internal link answers", async () => {
    const broken = [];
    for (const href of linked) {
      const res = await page.request.get(`${site}${href}`);
      if (res.status() !== 200) broken.push(`${href} ${res.status()}`);
    }
    if (broken.length) throw new Error(broken.join(", "));
  });

  await r.step("404 offers a way home", async () => {
    const res = await page.goto(`${site}/no-such-page`);
    if (res?.status() !== 404) throw new Error(`status ${res?.status()}`);
    await page.getByRole("link", { name: "Home" }).waitFor();
    await assertNoHorizontalScroll(page, "404");
  });

  failed += r.done();
  await context.close();
}

await browser.close();
process.exit(failed ? 1 : 0);
