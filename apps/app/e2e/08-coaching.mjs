// Coaching (D-044, slice 2): two accounts at 390x844. Account A becomes a coach (profile, Coach
// Terms, a one-on-one listing, weekly availability, publish), B finds A's page, requests a time
// from the server's slots with the Refund Policy acknowledged and the requests-only note shown,
// A confirms, B opens the DM from the booking; then A marks the session done and B reviews it.
// Cleanup: A archives the listing, clears the weekly times and pauses the coach page (bookings
// and the review stay; nothing in the app deletes them).
//
// Phases (E2E_PHASE): "book" sets up and books; "finish" completes and reviews; "all" (default)
// runs both, and the finish steps say SKIP while the session has not ended yet. A slot needs an
// hour's notice, so between the phases run supabase/staging/qa_coaching_past.sql as the
// staging_file of a staging-only migrate.yml run: it moves the test accounts' confirmed bookings
// into the past. The booking id is kept in E2E_QA_DIR/coaching.json. Output names steps only.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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

skipUnless(
  env.email && env.password && env.emailB && env.passwordB,
  "E2E_EMAIL/_B and E2E_PASSWORD/_B are not set",
);
const pw = loadPlaywright();
skipUnless(pw, "playwright is not installed");

const phase = process.env.E2E_PHASE || "all";
const stateFile = join(env.outDir, "coaching.json");
const saved = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, "utf8")) : {};
const save = (s) => {
  mkdirSync(env.outDir, { recursive: true });
  writeFileSync(stateFile, JSON.stringify({ ...saved, ...s }));
};

const browser = await pw.chromium.launch();
const A = await openContext(browser, VIEWPORTS.phone);
const B = await openContext(browser, VIEWPORTS.phone);
const pa = A.page;
const pb = B.page;
const r = makeRunner("coaching");
const stamp = Date.now().toString(36);
const title = `E2E tennis ${stamp}`;

let aHandle = saved.aHandle || "";
let listingId = saved.listingId || "";
let bookingId = saved.bookingId || "";

async function handleOf(page) {
  await page.goto(`${env.base}/you`);
  const sec = page.locator("main section").first();
  await sec.locator("p").nth(1).waitFor({ timeout: 20000 });
  return (await sec.locator("p").nth(1).innerText()).trim().replace(/^@/, "");
}

/** Waits up to ms for a locator to show (isVisible itself never waits). */
const visible = (loc, ms) =>
  loc
    .waitFor({ state: "visible", timeout: ms })
    .then(() => true)
    .catch(() => false);

/** Accepts the Community guidelines sheet when it opens (first booking or coach profile). */
async function agreeIfAsked(page) {
  const agree = page.getByRole("button", { name: "I agree" });
  if (await visible(agree, 4000)) await agree.click();
}

async function noSideways(page, label) {
  await page.waitForTimeout(300);
  await assertNoHorizontalScroll(page, label);
}

await r.step("sign in both accounts", async () => {
  await signIn(pa, env.email, env.password);
  await signIn(pb, env.emailB, env.passwordB);
  aHandle = await handleOf(pa);
  if (!aHandle) throw new Error("could not read A's handle");
  save({ aHandle });
});

if (phase === "book" || phase === "all") {
  await r.step("You tab shows Coaching; coach home or Become a coach", async () => {
    await pa
      .getByRole("link", { name: /Become a coach|Coach home/ })
      .first()
      .waitFor({ timeout: 20000 });
    await pa.goto(`${env.base}/coach`);
    await pa
      .getByText(/Coach on Activity Planet|Your coach page is/)
      .first()
      .waitFor({ timeout: 20000 });
    await shot(pa, "coach-01-home");
    await noSideways(pa, "coach home");
  });

  await r.step("A creates or saves the coach profile with the Coach Terms", async () => {
    await pa.goto(`${env.base}/coach/profile`);
    const headline = pa.getByLabel("Headline");
    await headline.waitFor({ timeout: 20000 });
    await headline.fill("Tennis coach for every level");
    const inPerson = pa.getByRole("switch", { name: "In person" });
    if ((await inPerson.getAttribute("aria-checked")) !== "true") await inPerson.click();
    const home = pa.getByRole("button", { name: "My home location" });
    // The saved home loads after the form; a new coach starts from it.
    await pa
      .waitForFunction(
        () =>
          [...document.querySelectorAll("button")].some(
            (b) => b.textContent?.includes("My home location") && !b.disabled,
          ),
        null,
        { timeout: 15000 },
      )
      .catch(() => undefined);
    if (await home.isEnabled().catch(() => false)) await home.click();
    const area = pa.getByLabel("Area name (public)");
    if (!(await area.inputValue())) await area.fill("Test area");
    const terms = pa.getByRole("checkbox");
    if (await terms.isVisible().catch(() => false)) await terms.check();
    await noSideways(pa, "coach profile");
    await shot(pa, "coach-02-profile");
    await pa.getByRole("button", { name: /Create coach profile|^Save$/ }).click();
    await agreeIfAsked(pa);
    await pa.waitForURL((u) => u.pathname === "/coach", { timeout: 30000 });
  });

  await r.step("A creates a one-on-one listing (online group is not offered)", async () => {
    await pa.goto(`${env.base}/coach/listings/new`);
    await pa.getByLabel("Title").waitFor({ timeout: 20000 });
    await pa.getByLabel("Title").fill(title);
    await pa.getByLabel("Description").fill("One hour on the court. Bring a racket.");
    await pa.getByLabel("Price").fill("40");
    await pa.getByLabel("Currency").fill("usd");
    await pa.getByText("More options").click();
    await pa.getByLabel("Notice (hours)").fill("1");
    await pa.getByLabel("Where to meet (private)").fill("North gate of the courts");
    await noSideways(pa, "listing form");
    await pa.getByRole("button", { name: "Create listing" }).click();
    await pa.waitForURL((u) => /^\/coach\/listings\/[0-9a-f-]{36}$/.test(u.pathname), {
      timeout: 30000,
    });
    listingId = new URL(pa.url()).pathname.split("/").pop();
    save({ listingId });
    await shot(pa, "coach-03-listing");
  });

  await r.step("A sets weekly availability and sees the two-week preview", async () => {
    await pa.goto(`${env.base}/coach/availability`);
    await pa.getByRole("button", { name: "Add a window" }).waitFor({ timeout: 20000 });
    // Start from none so reruns don't pile up windows.
    for (;;) {
      const rm = pa.getByRole("button", { name: /^Remove .* window$/ }).first();
      if (!(await rm.isVisible().catch(() => false))) break;
      await rm.click();
    }
    for (let d = 1; d <= 7; d++) {
      await pa.getByRole("button", { name: "Add a window" }).click();
      const i = d - 1;
      await pa.getByLabel("Day").nth(i).selectOption(String(d));
      await pa.getByLabel("From").nth(i).fill("00:00");
      await pa.getByLabel("To").nth(i).fill("23:30");
    }
    await pa.getByRole("button", { name: "Save weekly times" }).click();
    await pa.getByText("Availability saved.").waitFor({ timeout: 20000 });
    await pa.getByRole("list", { name: "Open times" }).waitFor({ timeout: 20000 });
    await noSideways(pa, "availability");
    await shot(pa, "coach-04-availability");
  });

  await r.step("A publishes the coach page", async () => {
    await pa.goto(`${env.base}/coach`);
    const publish = pa.getByRole("button", { name: "Publish" });
    if (await visible(publish, 15000)) await publish.click();
    await pa.getByText("live", { exact: true }).waitFor({ timeout: 20000 });
    // Requests only: no payout entry while payments are off.
    if (
      await pa
        .getByRole("link", { name: /Get paid in the app/ })
        .isVisible()
        .catch(() => false)
    )
      throw new Error("payout entry shown while payments are off");
  });

  await r.step("B browses coaches (near you, online) at 390px", async () => {
    await pb.goto(`${env.base}/coaches`);
    await pb.getByRole("radiogroup", { name: "Where" }).waitFor({ timeout: 20000 });
    await noSideways(pb, "coaches near");
    await pb.getByRole("radio", { name: "Online" }).click();
    await pb.waitForTimeout(800);
    await noSideways(pb, "coaches online");
    await shot(pb, "coach-05-browse");
  });

  await r.step("B opens A's page: listing, price, self-reported labels, Message", async () => {
    await pb.goto(`${env.base}/coaches/${aHandle}`);
    await pb.getByText(title).waitFor({ timeout: 20000 });
    await pb.getByText("$40").first().waitFor();
    await pb.getByRole("button", { name: "Message" }).waitFor();
    await noSideways(pb, "coach page");
    await shot(pb, "coach-06-page");
  });

  await r.step(
    "B requests a time from the server's slots with the policy acknowledged",
    async () => {
      await pb.goto(`${env.base}/coaches/${aHandle}/book/${listingId}`);
      const times = pb.getByRole("list", { name: "Times" });
      await times.waitFor({ timeout: 20000 });
      await pb.getByText(/Payment is arranged directly with/).waitFor();
      if (
        await pb
          .getByRole("button", { name: /^Pay/ })
          .isVisible()
          .catch(() => false)
      )
        throw new Error("Pay shown while payments are off");
      await times.getByRole("button").first().click();
      await pb.getByLabel("Note for the coach (optional)").fill("Intermediate, working on serves.");
      await pb.getByRole("checkbox").check();
      await noSideways(pb, "book page");
      await shot(pb, "coach-07-book");
      await pb.getByRole("button", { name: "Send request" }).click();
      await agreeIfAsked(pb);
      await pb.waitForURL((u) => /^\/bookings\/[0-9a-f-]{36}$/.test(u.pathname), {
        timeout: 30000,
      });
      bookingId = new URL(pb.url()).pathname.split("/").pop();
      save({ bookingId });
      await pb.getByText("Waiting for the coach").waitFor({ timeout: 20000 });
    },
  );

  await r.step("A sees the request in the inbox and on coach home, and confirms", async () => {
    await pa.goto(`${env.base}/coach`);
    await pa.getByRole("list", { name: "Requests" }).getByText(title).waitFor({ timeout: 20000 });
    await pa.goto(`${env.base}/bookings/${bookingId}`);
    await pa.getByText("Note from your client").waitFor({ timeout: 20000 });
    await noSideways(pa, "booking (coach)");
    await pa.getByRole("button", { name: "Confirm", exact: true }).click();
    await pa.getByText("Confirmed", { exact: true }).first().waitFor({ timeout: 20000 });
    await pa.getByText("North gate of the courts").waitFor({ timeout: 20000 });
    await shot(pa, "coach-08-confirmed");
  });

  await r.step("B sees it confirmed with the meeting place, then messages the coach", async () => {
    await pb.goto(`${env.base}/bookings/${bookingId}`);
    await pb.getByText("North gate of the courts").waitFor({ timeout: 20000 });
    await pb.getByRole("button", { name: "Cancel booking" }).waitFor();
    await pb.getByRole("button", { name: "Message" }).click();
    await pb.waitForURL((u) => /^\/chats\/[0-9a-f-]{36}$/.test(u.pathname), { timeout: 30000 });
    await pb.getByRole("textbox", { name: "Message" }).waitFor({ timeout: 20000 });
    await pb.getByRole("link", { name: new RegExp(title) }).waitFor({ timeout: 20000 });
    await shot(pb, "coach-09-dm");
  });

  await r.step("bookings lists for both sides", async () => {
    await pb.goto(`${env.base}/bookings`);
    await pb
      .getByRole("list", { name: "Bookings" })
      .getByText(title)
      .first()
      .waitFor({ timeout: 20000 });
    await noSideways(pb, "bookings list");
    await pa.goto(`${env.base}/bookings?role=coach`);
    await pa
      .getByRole("list", { name: "Bookings" })
      .getByText(title)
      .first()
      .waitFor({ timeout: 20000 });
  });
}

if (phase === "finish" || phase === "all") {
  let ended = false;
  await r.step("the session has ended (qa_coaching_past.sql), A marks it done", async () => {
    if (!bookingId) throw new Error("no booking id; run the book phase first");
    await pa.goto(`${env.base}/bookings/${bookingId}`);
    await pa.getByText("Timeline").waitFor({ timeout: 20000 });
    const done = pa.getByRole("button", { name: "Mark as done" });
    if (!(await visible(done, 5000))) {
      if (
        await pa
          .getByText("Completed", { exact: true })
          .first()
          .isVisible()
          .catch(() => false)
      ) {
        ended = true;
        return;
      }
      console.log(
        "SKIP: the session hasn't ended; run supabase/staging/qa_coaching_past.sql, then E2E_PHASE=finish",
      );
      return;
    }
    await done.click();
    await pa.getByText("Completed", { exact: true }).first().waitFor({ timeout: 20000 });
    ended = true;
  });

  if (ended) {
    await r.step("B reviews the completed session", async () => {
      await pb.goto(`${env.base}/bookings/${bookingId}`);
      await pb.getByRole("radiogroup", { name: "Rating" }).waitFor({ timeout: 20000 });
      await pb.getByRole("radio", { name: "5 stars" }).click();
      await pb.getByLabel(/Tell others how it went/).fill(`Great session ${stamp}`);
      await pb.getByRole("button", { name: "Post review" }).click();
      await pb.getByText(`Great session ${stamp}`).waitFor({ timeout: 20000 });
      await noSideways(pb, "review");
      await shot(pb, "coach-10-review");
    });

    await r.step("the review is on A's page", async () => {
      await pb.goto(`${env.base}/coaches/${aHandle}`);
      await pb.getByText(`Great session ${stamp}`).waitFor({ timeout: 20000 });
    });
  }

  await r.step("cleanup: archive the listing, clear weekly times, pause the page", async () => {
    if (listingId) {
      await pa.goto(`${env.base}/coach/listings/${listingId}`);
      const archive = pa.getByRole("button", { name: "Archive" });
      if (await visible(archive, 15000)) {
        await archive.click();
        await pa.waitForURL((u) => u.pathname === "/coach", { timeout: 20000 });
      }
    }
    await pa.goto(`${env.base}/coach/availability`);
    await pa.getByRole("button", { name: "Add a window" }).waitFor({ timeout: 20000 });
    for (;;) {
      const rm = pa.getByRole("button", { name: /^Remove .* window$/ }).first();
      if (!(await rm.isVisible().catch(() => false))) break;
      await rm.click();
    }
    await pa.getByRole("button", { name: "Save weekly times" }).click();
    await pa.getByText("Availability saved.").waitFor({ timeout: 20000 });
    await pa.goto(`${env.base}/coach`);
    const pause = pa.getByRole("button", { name: "Pause my page" });
    if (await visible(pause, 10000)) await pause.click();
  });
}

await r.step("no page errors", async () => {
  const bad = [...A.problems, ...B.problems].filter(
    (p) => p.startsWith("pageerror") || /http 5\d\d/.test(p),
  );
  if (bad.length) throw new Error(bad.slice(0, 3).join(" | "));
});

await browser.close();
process.exit(r.done() ? 1 : 0);
