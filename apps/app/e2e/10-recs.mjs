// Recommendations and PWA polish (RECS_DESIGN slice 2): For you on Home with reason chips,
// "Not interested" removes a card (then Undo puts it back), "Why am I seeing this?", Similar
// plans on an event page, the other rows where the account has them (reported, not failed:
// they depend on the account's hubs, coaches and shared plans), the privacy switches in You,
// the install card (iPhone instructions, hidden when running installed) and the "A new version
// is ready" toast on a simulated waiting service worker. Account A only; output names steps only.
// With E2E_SITE_URL (apps/web, `next build` + `next start`) it also checks the landing page at
// both widths: no sideways scroll, the week cards, the city picker, no location request before a
// tap, alt text on every image, the LCP element and text contrast.
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

skipUnless(env.email && env.password, "E2E_EMAIL and E2E_PASSWORD are not set");
const pw = loadPlaywright();
skipUnless(pw, "playwright is not installed");

const IPHONE_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

// E2E_ONLY=landing runs just the landing page checks.
const only = process.env.E2E_ONLY;
const browser = await pw.chromium.launch();
let failed = 0;

/* ------------------------------------------------------------------ */
/* Rows, signed in, phone width                                          */
/* ------------------------------------------------------------------ */
if (only !== "landing") {
  const { context, page, problems } = await openContext(browser, MAIN_VIEWPORT);
  const r = makeRunner("recs");
  const forYou = page.getByTestId("for-you");
  const cards = forYou.getByTestId("rec-event-card");
  const cardHrefs = async () =>
    forYou
      .locator('[data-testid="rec-event-card"] a[href^="/events/"]')
      .evaluateAll((as) => as.map((a) => a.getAttribute("href")));

  await r.step("sign in", () => signIn(page, env.email, env.password));

  await r.step("For you renders with chips", async () => {
    await page.goto(`${env.base}/`);
    await forYou.waitFor({ timeout: 25000 });
    const n = await cards.count();
    if (n < 3) throw new Error(`expected at least 3 cards, saw ${n}`);
    for (let i = 0; i < Math.min(n, 3); i += 1) {
      const chips = await cards.nth(i).getByTestId("reason-chip").count();
      if (chips < 1 || chips > 2) throw new Error(`card ${i + 1} has ${chips} chips`);
    }
    await assertNoHorizontalScroll(page, "/ with For you");
    await shot(page, "recs-01-for-you");
  });

  await r.step("Why am I seeing this?", async () => {
    await cards
      .first()
      .getByRole("button", { name: /^More about/ })
      .click();
    await page.getByRole("button", { name: "Why am I seeing this?" }).click();
    const dialog = page.getByRole("dialog", { name: "Why am I seeing this?" });
    await dialog.waitFor();
    if ((await dialog.getByRole("listitem").count()) < 1) throw new Error("no reasons listed");
    await shot(page, "recs-02-why");
    await page.keyboard.press("Escape");
    await dialog.waitFor({ state: "hidden" });
  });

  await r.step("Not interested removes a card, Undo brings it back", async () => {
    const before = await cardHrefs();
    const target = before[0];
    await cards
      .first()
      .getByRole("button", { name: /^More about/ })
      .click();
    await page.getByRole("button", { name: "Not interested" }).click();
    await page.waitForFunction(
      (href) =>
        !document.querySelector(
          `[data-testid="for-you"] [data-testid="rec-event-card"] a[href="${href}"]`,
        ),
      target,
      { timeout: 5000 },
    );
    await shot(page, "recs-03-dismissed");
    // Keep the account as it was: Undo, then the row refetches with the card.
    await page.getByRole("button", { name: "Undo" }).click();
    await page.waitForFunction(
      (href) =>
        Boolean(
          document.querySelector(
            `[data-testid="for-you"] [data-testid="rec-event-card"] a[href="${href}"]`,
          ),
        ),
      target,
      { timeout: 15000 },
    );
  });

  await r.step("Similar plans on an event page", async () => {
    const hrefs = (await cardHrefs()).slice(0, 4);
    let found = false;
    for (const href of hrefs) {
      await page.goto(`${env.base}${href}`);
      await page.waitForLoadState("networkidle").catch(() => undefined);
      const similar = page.getByTestId("similar-plans");
      if (await similar.count()) {
        await similar.scrollIntoViewIfNeeded();
        const n = await similar.getByTestId("rec-event-card").count();
        if (n < 1 || n > 6) throw new Error(`Similar plans shows ${n} cards`);
        if (await similar.locator(`a[href="${href}"]`).count())
          throw new Error("Similar plans lists the plan itself");
        await assertNoHorizontalScroll(page, "event with Similar plans");
        await shot(page, "recs-04-similar");
        found = true;
        break;
      }
    }
    if (!found) throw new Error("no Similar plans on the first For you plans");
  });

  const optional = [
    ["/hubs", "hubs-you-may-like", "rec-hub-card"],
    ["/coaches", "coaches-for-you", "rec-coach-card"],
    ["/you/met", "people-you-might-click-with", "rec-person-card"],
  ];
  for (const [path, row, card] of optional) {
    await r.step(`${path} loads (row reported)`, async () => {
      await page.goto(`${env.base}${path}`);
      await page.waitForLoadState("networkidle").catch(() => undefined);
      await page.waitForTimeout(1000);
      if (await page.getByRole("heading", { name: "Something broke" }).count())
        throw new Error("error screen");
      await assertNoHorizontalScroll(page, path);
      const n = await page.getByTestId(row).getByTestId(card).count();
      console.log(`  note: ${row} shows ${n} card(s)`);
      await shot(page, `recs-05${path.replace(/[^a-z0-9]+/gi, "_")}`);
    });
  }

  await r.step("You has the recommendation privacy switches", async () => {
    await page.goto(`${env.base}/you`);
    for (const name of [
      "Suggest me to people I share plans with",
      "Use my activity to personalize recommendations",
    ]) {
      const sw = page.getByRole("switch", { name: new RegExp(name) });
      await sw.waitFor({ timeout: 15000 });
      if ((await sw.getAttribute("aria-checked")) === null) throw new Error(`${name}: no state`);
    }
    await assertNoHorizontalScroll(page, "/you");
  });

  console.log(
    problems.length
      ? `PROBLEMS (recs):\n  ${[...new Set(problems)].join("\n  ")}`
      : "PROBLEMS (recs): none",
  );
  failed += r.done();
  await context.close();
}

/* ------------------------------------------------------------------ */
/* Install card                                                          */
/* ------------------------------------------------------------------ */
if (only !== "landing") {
  const r = makeRunner("install");
  const iphone = { ...VIEWPORTS.phone };
  await r.step("iPhone browser: the card shows Share instructions", async () => {
    const context = await browser.newContext({
      viewport: iphone,
      userAgent: IPHONE_UA,
      serviceWorkers: "block",
    });
    const page = await context.newPage();
    await signIn(page, env.email, env.password);
    await page.goto(`${env.base}/you`);
    const card = page.locator('[data-testid="install-card"][data-placement="you"]');
    await card.waitFor({ timeout: 15000 });
    await card.getByRole("button", { name: "Show me how" }).click();
    await page.getByRole("dialog", { name: "Add to Home Screen" }).waitFor();
    await shot(page, "recs-06-install-ios");
    await assertNoHorizontalScroll(page, "/you install");
    await context.close();
  });

  await r.step("installed (standalone): no card", async () => {
    const context = await browser.newContext({
      viewport: iphone,
      userAgent: IPHONE_UA,
      serviceWorkers: "block",
    });
    await context.addInitScript(() => {
      const real = window.matchMedia.bind(window);
      window.matchMedia = (q) =>
        /display-mode:\s*standalone/.test(q)
          ? {
              matches: true,
              media: q,
              onchange: null,
              addEventListener() {},
              removeEventListener() {},
              addListener() {},
              removeListener() {},
              dispatchEvent: () => false,
            }
          : real(q);
    });
    const page = await context.newPage();
    await signIn(page, env.email, env.password);
    await page.goto(`${env.base}/you`);
    await page.getByRole("switch").first().waitFor({ timeout: 15000 });
    if (await page.getByTestId("install-card").count())
      throw new Error("install card shown while installed");
    await context.close();
  });
  failed += r.done();
}

/* ------------------------------------------------------------------ */
/* Update toast                                                          */
/* ------------------------------------------------------------------ */
if (only !== "landing") {
  const r = makeRunner("update");
  await r.step("a waiting worker shows 'A new version is ready'", async () => {
    const context = await browser.newContext({
      viewport: VIEWPORTS.phone,
      serviceWorkers: "allow",
    });
    const page = await context.newPage();
    await page.goto(`${env.base}/auth/sign-in`);
    // The app registers /sw.js; wait until it is active.
    await page.waitForFunction(
      async () => {
        const reg = await navigator.serviceWorker.getRegistration();
        return Boolean(reg?.active);
      },
      null,
      { timeout: 30000 },
    );
    if (await page.getByTestId("update-toast").count()) throw new Error("toast before any update");
    // A second copy of the worker under another URL counts as an update: it installs and, now
    // that the worker no longer skips waiting, waits for the page's say-so.
    await page.evaluate(() => navigator.serviceWorker.register("/sw.js?e2e-update=1"));
    const toast = page.getByTestId("update-toast");
    await toast.waitFor({ timeout: 30000 });
    await shot(page, "recs-07-update-toast");
    await Promise.all([
      page.waitForEvent("load", { timeout: 30000 }),
      toast.getByRole("button", { name: "Reload" }).click(),
    ]);
    await page.waitForFunction(
      () => String(navigator.serviceWorker.controller?.scriptURL ?? "").includes("e2e-update"),
      null,
      { timeout: 15000 },
    );
    if (await page.getByTestId("update-toast").count()) throw new Error("toast after reload");
    // Leave no stray worker behind for other flows.
    await page.evaluate(async () => {
      for (const reg of await navigator.serviceWorker.getRegistrations()) await reg.unregister();
    });
    await context.close();
  });
  failed += r.done();
}

/* ------------------------------------------------------------------ */
/* Landing page (apps/web)                                               */
/* ------------------------------------------------------------------ */
const site = process.env.E2E_SITE_URL;
if (site) {
  for (const [vpName, viewport] of Object.entries(VIEWPORTS)) {
    const { context, page, problems } = await openContext(browser, viewport);
    const r = makeRunner(`landing-${vpName}`);
    await context.addInitScript(() => {
      window.__geoCalls = 0;
      const geo = navigator.geolocation;
      if (geo) {
        const real = geo.getCurrentPosition.bind(geo);
        geo.getCurrentPosition = (...args) => {
          window.__geoCalls += 1;
          return real(...args);
        };
      }
      window.__lcp = null;
      try {
        new PerformanceObserver((list) => {
          const last = list.getEntries().at(-1);
          if (last) window.__lcp = { tag: last.element?.tagName ?? null, time: last.startTime };
        }).observe({ type: "largest-contentful-paint", buffered: true });
      } catch {
        /* no LCP API */
      }
    });

    await r.step("renders, no sideways scroll, Atlanta by default", async () => {
      await page.goto(`${site}/`);
      await page.getByRole("heading", { level: 1 }).waitFor();
      await page.getByText("Showing plans around Atlanta. Pick your city to see yours.").waitFor();
      await assertNoHorizontalScroll(page, "landing");
      for (const name of ["This week near you", "How it works", "On your phone"])
        await page.getByRole("heading", { name }).waitFor();
      if (await page.getByText(/waitlist/i).count()) throw new Error("mentions a waitlist");
      await shot(page, `landing-${vpName}-01`);
      await page.screenshot({
        path: `${env.outDir}/landing-${vpName}-full.png`,
        fullPage: true,
      });
    });

    await r.step("no location request before a tap", async () => {
      const calls = await page.evaluate(() => window.__geoCalls);
      if (calls !== 0) throw new Error(`geolocation called ${calls} time(s) on load`);
    });

    await r.step("city picker swaps the cards", async () => {
      const box = page.getByRole("combobox", { name: "Your city" });
      await box.fill("Lond");
      await page.getByRole("option", { name: /^London/ }).click();
      await page.getByText("Showing plans around London.").waitFor({ timeout: 15000 });
      await assertNoHorizontalScroll(page, "landing, London");
      await shot(page, `landing-${vpName}-02-london`);
      // Back to the default for the next run.
      await box.fill("Atl");
      await page.getByRole("option", { name: /^Atlanta/ }).click();
      await page.getByText("Showing plans around Atlanta.", { exact: false }).waitFor();
    });

    await r.step("images have alt text, LCP is sized", async () => {
      const missing = await page.$$eval("img", (imgs) =>
        imgs.filter((i) => !i.hasAttribute("alt")).map((i) => i.getAttribute("src")),
      );
      if (missing.length) throw new Error(`${missing.length} image(s) without alt`);
      const unsized = await page.$$eval(
        "img",
        (imgs) =>
          imgs.filter((i) => !i.getAttribute("width") && !i.style.width && !i.className).length,
      );
      if (unsized) throw new Error(`${unsized} image(s) without a size`);
      const lcp = await page.evaluate(() => window.__lcp);
      console.log(
        `  note: LCP ${lcp ? `${lcp.tag} at ${Math.round(lcp.time)} ms` : "not reported"}`,
      );
      if (lcp?.tag === "IMG") throw new Error("the LCP element is an image");
    });

    await r.step("text contrast (AA)", async () => {
      const low = await page.evaluate(() => {
        const parse = (c) => {
          const m = c.match(/rgba?\(([^)]+)\)/);
          if (!m) return null;
          const [r, g, b, a = 1] = m[1]
            .split(/[ ,/]+/)
            .filter(Boolean)
            .map(Number);
          return { r, g, b, a };
        };
        const lum = ({ r, g, b }) => {
          const f = (v) => {
            const s = v / 255;
            return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
          };
          return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
        };
        const bgOf = (el) => {
          for (let n = el; n; n = n.parentElement) {
            const c = parse(getComputedStyle(n).backgroundColor);
            if (c && c.a > 0.5) return c;
          }
          return { r: 255, g: 255, b: 255, a: 1 };
        };
        const out = [];
        for (const el of document.querySelectorAll("body *")) {
          const own = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());
          if (!own || el.closest("svg")) continue;
          const st = getComputedStyle(el);
          if (
            st.visibility === "hidden" ||
            st.display === "none" ||
            el.getClientRects().length === 0
          )
            continue;
          const fg = parse(st.color);
          if (!fg) continue;
          const l1 = lum(fg);
          const l2 = lum(bgOf(el));
          const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
          const size = parseFloat(st.fontSize);
          const large = size >= 24 || (size >= 18.66 && Number(st.fontWeight) >= 700);
          if (ratio < (large ? 3 : 4.5)) out.push(`${el.tagName} ${ratio.toFixed(2)}`);
        }
        return out;
      });
      if (low.length)
        throw new Error(
          `${low.length} low-contrast text element(s): ${low.slice(0, 5).join(", ")}`,
        );
    });

    console.log(
      problems.length
        ? `PROBLEMS (landing-${vpName}):\n  ${[...new Set(problems)].join("\n  ")}`
        : `PROBLEMS (landing-${vpName}): none`,
    );
    failed += r.done();
    await context.close();
  }
}

await browser.close();
process.exit(failed ? 1 : 0);
