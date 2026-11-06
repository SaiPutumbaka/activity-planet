// Safety and You: B opens A's person row on A's plan (E2E_QA_DIR/event-id.txt from 03-plan.mjs,
// or E2E_EVENT_ID) and mutes, unmutes, reports and blocks A, then unblocks from You, Blocked
// accounts. A then checks the inbox, notification settings, Suggest a calendar's form and the
// account deletion page up to (not past) its confirm step. Both viewports for the You pages.
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
  MAIN_VIEWPORT,
} from "./lib.mjs";

skipUnless(
  env.email && env.password && env.emailB && env.passwordB,
  "E2E_EMAIL/_B and E2E_PASSWORD/_B are not set",
);
const pw = loadPlaywright();
skipUnless(pw, "playwright is not installed");
const idFile = join(env.outDir, "event-id.txt");
const eventId =
  process.env.E2E_EVENT_ID || (existsSync(idFile) ? readFileSync(idFile, "utf8").trim() : "");
skipUnless(eventId, "no event id (run 03-plan.mjs first or set E2E_EVENT_ID)");

const browser = await pw.chromium.launch();
let failed = 0;

/* B acts on A from A's plan */
{
  const { context, page, problems } = await openContext(browser, MAIN_VIEWPORT);
  const r = makeRunner("safety");
  let hostName = "";
  const openPerson = async () => {
    await page.goto(`${env.base}/events/${eventId}`);
    const btn = page.getByRole("button", { name: /^Profile and safety options for / }).first();
    await btn.waitFor({ timeout: 20000 });
    hostName = ((await btn.getAttribute("aria-label")) ?? "").replace(
      "Profile and safety options for ",
      "",
    );
    await btn.click();
    await page.getByRole("dialog").waitFor();
  };
  await r.step("sign in", () => signIn(page, env.emailB, env.passwordB));
  await r.step("mute from a person row, then unmute", async () => {
    await openPerson();
    await page.waitForTimeout(400);
    await shot(page, "safety-01-person-sheet");
    await page.getByRole("dialog").getByRole("button", { name: "Mute", exact: true }).click();
    await page.getByRole("heading", { name: `Mute ${hostName}?` }).waitFor();
    await page.getByRole("dialog").getByRole("button", { name: "Mute", exact: true }).click();
    await page.getByText(/muted/i).first().waitFor({ timeout: 10000 });
    await openPerson();
    await page.getByRole("dialog").getByRole("button", { name: "Unmute" }).click();
    await page.waitForTimeout(800);
  });
  await r.step("report from a person row", async () => {
    await openPerson();
    await page.getByRole("dialog").getByRole("button", { name: "Report" }).click();
    await page.getByRole("dialog").getByRole("radio").first().check();
    await page.getByLabel("Details (optional)").fill("QA e2e test report, please ignore.");
    await shot(page, "safety-02-report");
    await page.getByRole("button", { name: "Send report" }).click();
    await page
      .getByText(/report|thanks/i)
      .first()
      .waitFor({ timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, "safety-03-reported");
  });
  await r.step("block from a person row", async () => {
    await openPerson();
    await page.getByRole("dialog").getByRole("button", { name: "Block", exact: true }).click();
    await page.getByRole("heading", { name: `Block ${hostName}?` }).waitFor();
    await shot(page, "safety-04-block-confirm");
    await page.getByRole("dialog").getByRole("button", { name: "Block", exact: true }).click();
    await page.waitForTimeout(1500);
    await shot(page, "safety-05-after-block");
    await assertNoHorizontalScroll(page, "after block");
  });
  await r.step("Blocked accounts lists them; unblock", async () => {
    await page.goto(`${env.base}/you/blocked`);
    const unblock = page.getByRole("button", { name: `Unblock ${hostName}` });
    await unblock.waitFor({ timeout: 15000 });
    await shot(page, "safety-06-blocked-list");
    await unblock.click();
    await page.getByRole("dialog").getByRole("button", { name: "Unblock" }).click();
    await page.getByText("No one blocked").waitFor({ timeout: 10000 });
  });
  console.log(
    problems.length
      ? `PROBLEMS (safety):\n  ${[...new Set(problems)].join("\n  ")}`
      : "PROBLEMS (safety): none",
  );
  failed += r.done();
  await context.close();
}

/* A: You pages at both widths */
for (const [vpName, viewport] of Object.entries(VIEWPORTS)) {
  const { context, page, problems } = await openContext(browser, viewport);
  const r = makeRunner(`you-${vpName}`);
  const snap = (n) => shot(page, `you-${vpName}-${n}`);
  await r.step("sign in", () => signIn(page, env.email, env.password));
  await r.step("You tab", async () => {
    await page.goto(`${env.base}/you`);
    await page.getByRole("link", { name: /Blocked accounts/ }).waitFor({ timeout: 20000 });
    await snap("01-you");
    await assertNoHorizontalScroll(page, "you");
  });
  await r.step("inbox", async () => {
    await page.goto(`${env.base}/inbox`);
    await page
      .getByRole("link", { name: "Notification settings" })
      .or(page.getByRole("button", { name: "Notification settings" }))
      .first()
      .waitFor({ timeout: 20000 });
    await page.waitForLoadState("networkidle");
    await snap("02-inbox");
    await assertNoHorizontalScroll(page, "inbox");
  });
  await r.step("notification settings: toggle a topic and back", async () => {
    await page.goto(`${env.base}/you/notifications`);
    await page
      .getByRole("switch", { name: /Pause all email and push/ })
      .waitFor({ timeout: 20000 });
    await page.waitForLoadState("networkidle");
    await snap("03-notifications");
    await assertNoHorizontalScroll(page, "notifications");
    const sw = page.getByRole("switch").nth(1);
    const before = await sw.getAttribute("aria-checked");
    await sw.click();
    await page.waitForTimeout(1200);
    if ((await sw.getAttribute("aria-checked")) === before)
      throw new Error("switch did not change");
    await page.reload();
    await page
      .getByRole("switch", { name: /Pause all email and push/ })
      .waitFor({ timeout: 20000 });
    await page.waitForLoadState("networkidle");
    const sw2 = page.getByRole("switch").nth(1);
    if ((await sw2.getAttribute("aria-checked")) === before)
      throw new Error("switch change was not saved");
    await sw2.click();
    await page.waitForTimeout(1200);
  });
  await r.step("Suggest a calendar: rejects a non-calendar address", async () => {
    await page.goto(`${env.base}/suggest-calendar`);
    const field = page.getByRole("textbox").first();
    await field.waitFor({ timeout: 20000 });
    await field.fill("not a url");
    await page
      .getByRole("button", { name: /Suggest|Send/ })
      .first()
      .click();
    await page.getByRole("alert").first().waitFor({ timeout: 5000 });
    await snap("04-suggest-invalid");
  });
  await r.step("delete account up to the confirm step", async () => {
    await page.goto(`${env.base}/you/delete`);
    const del = page.getByRole("button", { name: "Delete my account" });
    await del.waitFor({ timeout: 20000 });
    if (await del.isEnabled()) throw new Error("Delete is enabled before typing the confirm word");
    await page.getByLabel(/Type delete to confirm/).fill("delete");
    if (!(await del.isEnabled()))
      throw new Error("Delete stays disabled after typing the confirm word");
    await snap("05-delete-confirm");
    await assertNoHorizontalScroll(page, "delete");
    // Stop here: the account is not deleted.
  });
  console.log(
    problems.length
      ? `PROBLEMS (you-${vpName}):\n  ${[...new Set(problems)].join("\n  ")}`
      : `PROBLEMS (you-${vpName}): none`,
  );
  failed += r.done();
  await context.close();
}
await browser.close();
process.exit(failed ? 1 : 0);
