// Sign in, then first-run onboarding: birthday, about, hubs, where are you (a starter city),
// affiliation skipped. Run on a fresh account (E2E_EMAIL / E2E_PASSWORD); an onboarded account
// lands on Home and the onboarding steps are reported as skipped.
// Usage: E2E_EMAIL=... E2E_PASSWORD=... [E2E_CITY=Atlanta] node e2e/01-onboarding.mjs
import {
  env,
  skipUnless,
  loadPlaywright,
  openContext,
  shot,
  signIn,
  makeRunner,
  assertNoHorizontalScroll,
  MAIN_VIEWPORT,
} from "./lib.mjs";

const email = process.env.E2E_ONBOARD_EMAIL || env.email;
const password = process.env.E2E_ONBOARD_PASSWORD || env.password;
skipUnless(email && password, "E2E_EMAIL and E2E_PASSWORD are not set");
const pw = loadPlaywright();
skipUnless(pw, "playwright is not installed");

const city = process.env.E2E_CITY || "Atlanta";
const tag = process.env.E2E_TAG || "a";
const browser = await pw.chromium.launch();
const { page, problems } = await openContext(browser, MAIN_VIEWPORT);
const r = makeRunner(`onboarding-${tag}`);

await r.step("sign-up page renders", async () => {
  await page.goto(`${env.base}/auth/sign-up`);
  await page.getByRole("heading").first().waitFor();
  await assertNoHorizontalScroll(page, "sign-up");
  await shot(page, `onb-${tag}-00-sign-up`);
});

await r.step("sign in", async () => {
  await signIn(page, email, password);
});

// The app guard sends a fresh account on to /onboarding after sign-in lands on /.
await page.waitForLoadState("networkidle");
await page.waitForTimeout(1000);
const onboarding = new URL(page.url()).pathname === "/onboarding";
if (!onboarding) {
  console.log(`NOTE: already onboarded (landed on ${new URL(page.url()).pathname})`);
} else {
  await r.step("birthday", async () => {
    await page.getByRole("heading", { name: "When's your birthday?" }).waitFor();
    await shot(page, `onb-${tag}-01-birthday`);
    await page.getByLabel("Birthday").fill("1995-06-15");
    await page.getByRole("button", { name: "Continue" }).click();
  });
  await r.step("about", async () => {
    await page.getByLabel("First name").waitFor();
    await page.getByLabel("First name").fill(process.env.E2E_FIRST_NAME || "Qa");
    const handle = `qae2e${tag}${Date.now().toString(36).slice(-5)}`;
    await page.getByLabel("Handle").fill(handle);
    await page.waitForTimeout(1200);
    await shot(page, `onb-${tag}-02-about`);
    await assertNoHorizontalScroll(page, "about");
    await page.getByRole("button", { name: "Continue" }).click();
  });
  await r.step("hubs", async () => {
    await page.getByRole("heading", { name: "What are you into?" }).waitFor();
    await page.getByRole("searchbox", { name: "Search hubs" }).waitFor();
    // Pick the first three chips shown.
    const chips = page.locator("main section button");
    await chips.first().waitFor({ timeout: 15000 });
    for (let i = 0; i < 3; i++) await chips.nth(i).click();
    await shot(page, `onb-${tag}-03-hubs`);
    await assertNoHorizontalScroll(page, "hubs");
    await page.getByRole("button", { name: /Continue with 3 hubs/ }).click();
  });
  await r.step("where are you (starter city)", async () => {
    await page.getByRole("heading", { name: "Where are you?" }).waitFor();
    await page.getByRole("searchbox", { name: "Search for your city or neighborhood" }).fill(city);
    const option = page.getByRole("radiogroup", { name: "Places" }).getByRole("radio").first();
    await option.waitFor({ timeout: 10000 });
    await option.click();
    await shot(page, `onb-${tag}-04-location`);
    await assertNoHorizontalScroll(page, "location");
    await page.getByRole("button", { name: "Continue", exact: true }).click();
  });
  await r.step("affiliation skip", async () => {
    await page.getByRole("button", { name: "Skip" }).waitFor();
    await shot(page, `onb-${tag}-05-affiliation`);
    await page.getByRole("button", { name: "Skip" }).click();
    await page.waitForURL((u) => u.pathname === "/", { timeout: 20000 });
  });
}

await r.step("home after onboarding", async () => {
  await page.getByRole("heading", { name: /^Hi, / }).waitFor({ timeout: 20000 });
  await page.waitForLoadState("networkidle");
  await shot(page, `onb-${tag}-06-home`);
  await assertNoHorizontalScroll(page, "home");
});

console.log(
  problems.length ? `PROBLEMS:\n  ${[...new Set(problems)].join("\n  ")}` : "PROBLEMS: none",
);
await browser.close();
process.exit(r.done() ? 1 : 0);
