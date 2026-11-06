// Offline: the installed app opens without a connection. Signs in with service workers allowed,
// waits for the worker to take control, goes offline and opens a few routes: each must show the
// "You're offline" screen (not a spinner or "Something broke"), and the screen must recover on
// its own once the connection is back. Screenshots: offline-<route>.png in E2E_QA_DIR.
import {
  env,
  skipUnless,
  loadPlaywright,
  shot,
  signIn,
  makeRunner,
  MAIN_VIEWPORT,
} from "./lib.mjs";

skipUnless(env.email && env.password, "E2E_EMAIL and E2E_PASSWORD are not set");
const pw = loadPlaywright();
skipUnless(pw, "playwright is not installed");

const routes = ["/", "/hubs", "/you"];
const browser = await pw.chromium.launch();
const context = await browser.newContext({ viewport: MAIN_VIEWPORT });
const page = await context.newPage();
const run = makeRunner("offline");
const bodyText = async () => (await page.locator("body").innerText()).replace(/\s+/g, " ");

await run.step("sign in and let the service worker take control", async () => {
  await signIn(page, env.email, env.password);
  await page.goto(`${env.base}/`);
  await page.waitForFunction(() => navigator.serviceWorker?.controller != null, null, {
    timeout: 20000,
  });
});

await context.setOffline(true);
for (const route of routes) {
  await run.step(`offline ${route} says so`, async () => {
    await page.goto(`${env.base}${route}`, { timeout: 15000 });
    await page.getByText("You're offline").waitFor({ timeout: 10000 });
    await shot(page, `offline-${route.replace(/\W+/g, "_") || "home"}`);
  });
}

await run.step("back online, the screen loads again without a tap", async () => {
  await context.setOffline(false);
  await page.waitForFunction(() => !document.body.innerText.includes("You're offline"), null, {
    timeout: 20000,
  });
  if ((await bodyText()).includes("Something broke"))
    throw new Error("error screen after reconnect");
});

await browser.close();
process.exit(run.done() ? 1 : 0);
