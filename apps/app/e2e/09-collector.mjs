// Collector completion Slice 2, at 390x844 and 1280x800: an imported listing's source block
// ("Request removal" goes to the site's form with the event id, "Are you the organizer?"), the
// claim page (start a claim, the code with copy buttons, Check now), the organizer page, the
// calendar form's check, and the moderator tabs (Takedowns > Listings, Claims > Organizers,
// Health > Events; a member sees "Moderators only"). With E2E_SITE_URL (the web app, for
// example `pnpm --filter @ap/web start` on port 3000) it also opens /bot and /bot/remove?event=
// and sends the form, which answers with an error when the site has no service key.
// Starting a claim leaves a pending claim on the test account; it expires after 7 days.
// Usage: E2E_EMAIL=... E2E_PASSWORD=... [E2E_SITE_URL=http://localhost:3000] node e2e/09-collector.mjs
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
const site = (process.env.E2E_SITE_URL || "").replace(/\/+$/, "");

const settle = async (page) => {
  await page.waitForLoadState("networkidle").catch(() => undefined);
  await page
    .waitForFunction(() => !document.querySelector('[aria-busy="true"]'), null, { timeout: 15000 })
    .catch(() => undefined);
};

/** The first imported listing on Home's "Also happening" shelf, or on a hub page. */
async function findImportedEvent(page) {
  for (const path of ["/", "/hubs"]) {
    await page.goto(`${env.base}${path}`);
    await settle(page);
    const shelf = page.getByRole("region", { name: "Also happening" });
    const scope = (await shelf.count()) ? shelf : page.locator("main");
    const links = scope.locator("a[href^='/events/']");
    const n = Math.min(await links.count(), 12);
    for (let i = 0; i < n; i++) {
      const href = await links.nth(i).getAttribute("href");
      const id = href?.match(/^\/events\/([0-9a-f-]{36})/)?.[1];
      if (!id) continue;
      await page.goto(`${env.base}/events/${id}`);
      await settle(page);
      if (await page.getByRole("link", { name: "Request removal" }).count()) return id;
    }
  }
  return null;
}

const browser = await pw.chromium.launch();
let failed = 0;
let eventId = null;
for (const [vpName, viewport] of Object.entries(VIEWPORTS)) {
  const { page, context, problems } = await openContext(browser, viewport);
  const r = makeRunner(`collector-${vpName}`);
  const snap = (n) => shot(page, `collector-${vpName}-${n}`);

  await r.step("sign in", () => signIn(page, env.email, env.password));

  await r.step("imported listing: removal link and organizer link", async () => {
    eventId = eventId ?? (await findImportedEvent(page));
    if (!eventId) {
      console.log("  NOTE: no imported listing reachable from Home or Hubs for this account");
      return;
    }
    await page.goto(`${env.base}/events/${eventId}`);
    await settle(page);
    await snap("01-event");
    await assertNoHorizontalScroll(page, "event page");
    const removal = page.getByRole("link", { name: "Request removal" }).first();
    const href = (await removal.getAttribute("href")) ?? "";
    if (!href.includes(`/bot/remove?event=${eventId}`))
      throw new Error(`Request removal does not go to the form: ${href.split("?")[0]}`);
    const organizer = page.getByRole("link", { name: "Are you the organizer?" });
    const listedByOrganizer = await page.getByText("Listed by the organizer.").count();
    if (!(await organizer.count()) && !listedByOrganizer)
      throw new Error("neither Are you the organizer? nor Listed by the organizer");
  });

  await r.step("claim page: start a claim, the code, Check now", async () => {
    if (!eventId) return;
    await page.goto(`${env.base}/organizer/claim?event=${eventId}`);
    await settle(page);
    await snap("02-claim");
    await assertNoHorizontalScroll(page, "claim page");
    const start = page.getByRole("button", { name: "Get my code" });
    if (!(await start.count())) {
      const title = await page.locator("main h3").first().textContent();
      console.log(`  NOTE: claim form not offered: ${title}`);
      return;
    }
    const dns = page.getByRole("radio", { name: /A DNS record/ });
    if (await dns.count()) await dns.check();
    await start.click();
    const copy = page.getByRole("button", { name: /^Copy / }).first();
    const refused = page.getByRole("alert");
    await Promise.race([copy.waitFor({ timeout: 15000 }), refused.waitFor({ timeout: 15000 })]);
    if (await refused.count()) {
      // account_too_new, rate_limited: the database's rules, shown in plain words.
      console.log(`  NOTE: claim refused: ${(await refused.first().textContent())?.slice(0, 120)}`);
      return;
    }
    const code = await page.locator("main code").allTextContents();
    if (!code.some((c) => /^ap-verify-[a-z2-7]{24}$/.test(c.trim())))
      throw new Error("no ap-verify token shown");
    await snap("03-claim-code");
    await assertNoHorizontalScroll(page, "claim code");
    await page.getByRole("button", { name: "Check now" }).click();
    await page.locator("[data-sonner-toast]").first().waitFor({ timeout: 20000 });
  });

  await r.step("organizer page", async () => {
    await page.goto(`${env.base}/organizer`);
    await settle(page);
    await snap("04-organizer");
    await assertNoHorizontalScroll(page, "organizer page");
    await page.getByRole("heading", { name: "Your claims" }).waitFor({ timeout: 10000 });
    const cards = await page.locator("main article").count();
    const empty = await page.getByRole("heading", { name: "No claims yet" }).count();
    if (!cards && !empty) throw new Error("neither claims nor the empty state");
  });

  await r.step("connect a calendar: the link is checked first", async () => {
    await page.goto(`${env.base}/organizer/claim?feed=true`);
    await settle(page);
    await page.getByLabel("Public calendar link").fill("http://calendar.example.org/a.ics");
    await page.getByRole("button", { name: "Get my code" }).click();
    await page.getByText("Use the https:// or webcal:// link.").waitFor({ timeout: 5000 });
    await snap("05-feed-form");
    await assertNoHorizontalScroll(page, "feed form");
  });

  for (const [path, marker] of [
    ["/admin/takedowns?tab=listings", /requests|Moderators only/i],
    [
      "/admin/claims?tab=organizers",
      /Nothing here|Moderators only|Waiting for proof|Verified|Failed|Revoked/,
    ],
    ["/admin/health?tab=events", /Jobs|Moderators only/],
  ]) {
    await r.step(`moderator tab ${path.split("?")[0]}`, async () => {
      await page.goto(`${env.base}${path}`);
      await settle(page);
      await page.waitForTimeout(1000);
      await snap(`06-${path.replace(/[^a-z]+/gi, "_")}`);
      await assertNoHorizontalScroll(page, path);
      const text = (await page.locator("main").textContent()) ?? "";
      if (!marker.test(text)) throw new Error("the tab rendered neither its content nor the gate");
      if (await page.getByRole("heading", { name: "Something broke" }).count())
        throw new Error("error screen");
    });
  }

  if (site) {
    await r.step("site /bot", async () => {
      await page.goto(`${site}/bot`);
      await page.getByRole("heading", { name: "ActivityPlanetBot", level: 1 }).waitFor();
      await page.getByText("User-agent: ActivityPlanetBot").waitFor();
      await snap("07-bot");
      await assertNoHorizontalScroll(page, "/bot");
    });
    await r.step("site removal form, prefilled and sent", async () => {
      const id = eventId ?? "00000000-0000-4000-8000-000000000000";
      await page.goto(`${site}/bot/remove?event=${id}`);
      await page.getByText(id).waitFor();
      await assertNoHorizontalScroll(page, "/bot/remove");
      await page.getByRole("button", { name: "Send removal request" }).click();
      await page.getByRole("alert").getByText("Enter your name.").waitFor();
      await page.getByLabel("Your name").fill("QA Tester");
      await page.getByLabel("Email address we can reach you at").fill("qa@example.com");
      await page.getByRole("radio", { name: /I organize the event/ }).check();
      await page.getByRole("button", { name: "Send removal request" }).click();
      const answer = page.getByRole("status").or(page.getByRole("alert"));
      await answer.first().waitFor({ timeout: 15000 });
      await snap("08-remove-sent");
      console.log(
        (await page.getByRole("status").count())
          ? "  NOTE: the site filed the request (it has a service key)"
          : "  NOTE: the site answered with an error (no service key here)",
      );
    });
  }

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
