// Shows and games (D-041 slice 10, lane 1): once a Ticketmaster or SeatGeek run has posted
// shows near account A's home, Home has the "Shows and games" row with the sellers' credit and
// the Map has the Shows and games chip and list section. One account at 390x844 (or 1280x800
// with E2E_VIEWPORT=desktop). Output names steps and counts only, never titles.
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

skipUnless(env.email && env.password, "E2E_EMAIL and E2E_PASSWORD are not set");
const pw = loadPlaywright();
skipUnless(pw, "playwright is not installed");

const browser = await pw.chromium.launch();
const A = await openContext(browser, MAIN_VIEWPORT);
const pa = A.page;
const r = makeRunner("shows");

await r.step("sign in", async () => {
  await signIn(pa, env.email, env.password);
});

await r.step("Home has the Shows and games row with the sellers' credit", async () => {
  await pa.goto(`${env.base}/`);
  const heading = pa.getByRole("heading", { name: "Shows and games" });
  await heading.waitFor({ timeout: 30000 });
  await heading.scrollIntoViewIfNeeded();
  const row = pa.locator('section[aria-labelledby="shows-and-games"]');
  const cards = await row.getByRole("link").count();
  if (cards === 0) throw new Error("the row has no cards");
  await row
    .getByText(/Ticketmaster|SeatGeek/)
    .first()
    .waitFor({ timeout: 15000 });
  console.log(`NOTE shows / home: ${cards} links in the row`);
  await shot(pa, "shows-01-home-row");
  await assertNoHorizontalScroll(pa, "home with shows");
});

await r.step("Map has the Shows and games layer and list section", async () => {
  await pa.goto(`${env.base}/map`);
  const chips = pa.getByRole("group", { name: "Show on the map" });
  await chips.waitFor({ timeout: 30000 });
  const chip = chips
    .getByRole("button", { name: /Shows and games/ })
    .or(chips.getByRole("checkbox", { name: /Shows and games/ }));
  await chip.first().waitFor({ timeout: 20000 });
  await shot(pa, "shows-02-map");
  const list = pa
    .getByRole("button", { name: /^List/ })
    .or(pa.getByRole("link", { name: /^List/ }));
  if ((await list.count()) > 0) await list.first().click();
  await pa.getByText("Shows and games").last().waitFor({ timeout: 20000 });
  await shot(pa, "shows-03-map-list");
});

console.log(
  A.problems.length
    ? `PROBLEMS (shows):\n  ${[...new Set(A.problems)].join("\n  ")}`
    : "PROBLEMS (shows): none",
);
const failed = r.done();
await A.context.close();
await browser.close();
process.exit(failed ? 1 : 0);
