// Messaging (D-043): two accounts at 390x844. The photo gate, a message request from A to B
// found by handle (B accepts it from Requests), realtime delivery both ways without a reload,
// typing, delete own message, report a message, the Chats badge, then B blocks A and A's next
// message is refused and never reaches B; B unblocks to clean up. The plan chat button on A's
// plan (E2E_QA_DIR/event-id.txt from 03-plan.mjs, or E2E_EVENT_ID) if there is one.
// A message request needs A's account to be a day old: on staging, run
// supabase/staging/qa_account_age.sql first. Output names steps only, never user rows.
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

const browser = await pw.chromium.launch();
const A = await openContext(browser, VIEWPORTS.phone);
const B = await openContext(browser, VIEWPORTS.phone);
const pa = A.page;
const pb = B.page;
const r = makeRunner("messaging");
const stamp = Date.now().toString(36);
const LIVE_MS = 15000;

let aName = "";
let bName = "";
let bHandle = "";
let convPath = "";
let requestMode = false;

/** The name and handle at the top of the You tab. */
async function whoAmI(page) {
  await page.goto(`${env.base}/you`);
  const sec = page.locator("main section").first();
  await sec.locator("p").nth(1).waitFor({ timeout: 20000 });
  const name = (await sec.locator("p").nth(0).innerText()).trim();
  const handle = (await sec.locator("p").nth(1).innerText()).trim().replace(/^@/, "");
  const needsPhoto = await page
    .getByRole("link", { name: "Add photo" })
    .isVisible()
    .catch(() => false);
  return { name, handle, needsPhoto };
}

/** A plain JPEG made in the browser, for a profile photo. */
async function photoJpeg() {
  const p = await browser.newPage({ viewport: { width: 400, height: 400 } });
  await p.setContent(
    `<body style="margin:0"><div style="width:400px;height:400px;background:linear-gradient(135deg,#f59e0b,#0ea5e9)"></div></body>`,
  );
  const buf = await p.screenshot({ type: "jpeg", quality: 85 });
  await p.close();
  return buf;
}

async function addPhoto(page) {
  await page.goto(`${env.base}/you/photo`);
  await page.locator('input[type="file"]').setInputFiles({
    name: "qa-photo.jpg",
    mimeType: "image/jpeg",
    buffer: await photoJpeg(),
  });
  await page.getByRole("button", { name: "Save photo" }).click({ timeout: 20000 });
  await page.waitForURL((u) => u.pathname === "/you", { timeout: 30000 });
  await page.getByRole("link", { name: "Change photo" }).waitFor({ timeout: 20000 });
}

const composer = (page) => page.getByRole("textbox", { name: "Message" });

async function send(page, text) {
  await composer(page).fill(text);
  await composer(page).press("Enter");
}

/** A bubble with this exact text, in the conversation history (not the outbox). */
const bubble = (page, text) =>
  page.getByRole("list", { name: "Conversation history" }).getByText(text, { exact: true });

const msg1 = `Hello from A, e2e ${stamp}`;
const msg2 = `Hi A, B here ${stamp}`;
const msg3 = `A again, this one gets deleted ${stamp}`;
const msg4 = `A for the badge ${stamp}`;
const msg5 = `A after the block ${stamp}`;

await r.step("sign in both accounts", async () => {
  await signIn(pa, env.email, env.password);
  await signIn(pb, env.emailB, env.passwordB);
});

let aNeedsPhoto = false;
let bNeedsPhoto = false;
await r.step("read names and handles", async () => {
  const a = await whoAmI(pa);
  const b = await whoAmI(pb);
  aName = a.name;
  bName = b.name;
  bHandle = b.handle;
  aNeedsPhoto = a.needsPhoto;
  bNeedsPhoto = b.needsPhoto;
  if (!aName || !bName || !bHandle) throw new Error("could not read the You tab");
});

await r.step("Chats icon beside the inbox bell on Home, Hubs and You; Chats screen", async () => {
  for (const path of ["/", "/hubs", "/you"]) {
    await pa.goto(`${env.base}${path}`);
    await pa
      .getByRole("link", { name: /^Chats/ })
      .first()
      .waitFor({ timeout: 20000 });
    await pa
      .getByRole("link", { name: /^Inbox/ })
      .first()
      .waitFor();
    await assertNoHorizontalScroll(pa, `top bar ${path}`);
  }
  await pa
    .getByRole("link", { name: /^Chats/ })
    .first()
    .click();
  await pa.waitForURL((u) => u.pathname === "/chats");
  await pa.getByRole("radiogroup", { name: "Chats or requests" }).waitFor({ timeout: 20000 });
  await shot(pa, "msg-01-chats-list");
  await assertNoHorizontalScroll(pa, "chats list");
});

await r.step("photo gate: no photo, no new conversation, with a way to add one", async () => {
  if (!aNeedsPhoto) {
    console.log("NOTE messaging / photo gate: A already has a photo (an earlier run); skipped");
    return;
  }
  await pa.goto(`${env.base}/chats/new`);
  await pa.getByLabel("Search by handle").fill(bHandle);
  await pa.getByRole("button", { name: `Message ${bName}` }).click({ timeout: 20000 });
  await pa
    .getByText(/Add a profile photo to send messages/)
    .first()
    .waitFor({ timeout: 15000 });
  await shot(pa, "msg-02-photo-gate");
});

await r.step("add profile photos", async () => {
  if (aNeedsPhoto) await addPhoto(pa);
  if (bNeedsPhoto) await addPhoto(pb);
});

await r.step("A finds B by handle and starts a conversation (a message request)", async () => {
  await pa.goto(`${env.base}/chats/new`);
  await pa.getByLabel("Search by handle").fill(bHandle);
  await pa.getByRole("button", { name: `Message ${bName}` }).click({ timeout: 20000 });
  await pa.waitForURL((u) => /^\/chats\/[0-9a-f-]{36}$/.test(u.pathname), { timeout: 20000 });
  convPath = new URL(pa.url()).pathname;
  await composer(pa).or(pa.getByRole("status")).first().waitFor({ timeout: 20000 });
  requestMode = await pa
    .getByText("This is a message request")
    .isVisible()
    .catch(() => false);
  if (!requestMode)
    console.log("NOTE messaging / request: this pair already has an open DM (an earlier run)");
  await shot(pa, "msg-03-new-conversation");
  await assertNoHorizontalScroll(pa, "conversation");
});

await r.step("A sends the one message; the request then waits", async () => {
  if (!(await composer(pa).isVisible())) {
    // An earlier run left the DM closed by its block; writing again reopens it (start_dm).
    throw new Error(
      `composer missing: ${await pa
        .getByRole("status")
        .innerText()
        .catch(() => "")}`,
    );
  }
  await send(pa, msg1);
  await bubble(pa, msg1).waitFor({ timeout: 20000 });
  if (requestMode) {
    await pa.getByText(/Your request is waiting/).waitFor({ timeout: 15000 });
    await shot(pa, "msg-04-request-waiting");
  }
});

await r.step("B sees it under Requests and accepts", async () => {
  if (!requestMode) {
    await pb.goto(`${env.base}${convPath}`);
    await bubble(pb, msg1).waitFor({ timeout: 20000 });
    return;
  }
  await pb.goto(`${env.base}/chats?tab=requests`);
  await pb.getByRole("radio", { name: /Requests \(\d+\)/ }).waitFor({ timeout: 20000 });
  await shot(pb, "msg-05-requests-tab");
  await assertNoHorizontalScroll(pb, "requests tab");
  await pb
    .getByRole("list", { name: "Message requests" })
    .getByRole("link", { name: new RegExp(`^${aName}`) })
    .first()
    .click();
  await pb.waitForURL((u) => u.pathname === convPath, { timeout: 20000 });
  await bubble(pb, msg1).waitFor({ timeout: 20000 });
  await pb.getByLabel("Message request").waitFor();
  await shot(pb, "msg-06-request-banner");
  await pb.getByRole("button", { name: "Accept" }).click();
  await pb.getByText(/You can message .* now/).waitFor({ timeout: 15000 });
  await composer(pb).waitFor({ timeout: 15000 });
});

await r.step("realtime: B's reply reaches A without a reload", async () => {
  // A has sat on the conversation since sending; nothing reloads it.
  await send(pb, msg2);
  await bubble(pb, msg2).waitFor({ timeout: 20000 });
  await bubble(pa, msg2).waitFor({ timeout: LIVE_MS });
  // The request note is gone for A once B accepted (info refreshes on the signal or focus).
});

await r.step("realtime: A to B, and the typing line", async () => {
  await composer(pa).click();
  await pa.keyboard.type("typing a little", { delay: 60 });
  await pb.getByText(`${aName} is typing`).waitFor({ timeout: LIVE_MS });
  await shot(pb, "msg-07-typing");
  await composer(pa).fill("");
  await send(pa, msg3);
  await bubble(pb, msg3).waitFor({ timeout: LIVE_MS });
  await shot(pb, "msg-08-live");
});

await r.step("A deletes their own message; B sees it go", async () => {
  // Newest first in the DOM: the first of A's option buttons is msg3.
  await pa
    .getByRole("button", { name: /^Options for the message from you/ })
    .first()
    .click();
  const dialog = pa.getByRole("dialog");
  await dialog.getByRole("button", { name: "Delete message" }).click();
  await dialog.getByRole("button", { name: "Delete", exact: true }).click();
  await pa.getByText("Message deleted.").first().waitFor({ timeout: 15000 });
  await bubble(pb, msg3).waitFor({ state: "detached", timeout: LIVE_MS });
  await pb.getByText("Message deleted", { exact: true }).first().waitFor({ timeout: LIVE_MS });
});

await r.step("B reports one of A's messages", async () => {
  await pb
    .getByRole("button", { name: new RegExp(`^Options for the message from ${aName}`) })
    .first()
    .click();
  const dialog = pb.getByRole("dialog");
  await dialog.getByRole("button", { name: "Report message" }).click();
  await dialog.getByRole("radio").first().check();
  await dialog.getByLabel("Details (optional)").fill("QA e2e test report, please ignore.");
  await shot(pb, "msg-09-report-message");
  await dialog.getByRole("button", { name: "Send report" }).click();
  await pb
    .getByText(/A moderator will look at it|already reported/)
    .first()
    .waitFor({ timeout: 15000 });
});

await r.step("phone width: info, list and new message pages fit", async () => {
  for (const [page, path] of [
    [pa, `${convPath}/info`],
    [pa, "/chats"],
    [pa, "/chats/new"],
    [pb, "/you/met"],
  ]) {
    await page.goto(`${env.base}${path}`);
    await page.waitForLoadState("networkidle");
    await assertNoHorizontalScroll(page, path.replace(/[0-9a-f-]{36}/, ":id"));
  }
  await pa.goto(`${env.base}${convPath}/info`);
  await pa.getByRole("heading", { name: "Notifications" }).waitFor({ timeout: 20000 });
  await shot(pa, "msg-10-info");
});

await r.step("the Chats badge counts B's unread chat", async () => {
  await pa.goto(`${env.base}${convPath}`);
  await composer(pa).waitFor({ timeout: 20000 });
  await pb.goto(`${env.base}/you`);
  await pb
    .getByRole("link", { name: /^Chats/ })
    .first()
    .waitFor({ timeout: 20000 });
  await pb.waitForTimeout(1500);
  await send(pa, msg4);
  await bubble(pa, msg4).waitFor({ timeout: 20000 });
  await pb
    .getByRole("link", { name: /^Chats, \d+ unread/ })
    .first()
    .waitFor({ timeout: LIVE_MS + 15000 });
  await shot(pb, "msg-11-badge");
});

await r.step("B blocks A from chat info", async () => {
  await pb.goto(`${env.base}${convPath}/info`);
  await pb.getByRole("button", { name: `Block or report ${aName}` }).click({ timeout: 20000 });
  const dialog = pb.getByRole("dialog");
  await dialog.getByRole("button", { name: "Block", exact: true }).click();
  await pb.getByRole("heading", { name: `Block ${aName}?` }).waitFor();
  await dialog.getByRole("button", { name: "Block", exact: true }).click();
  await pb
    .getByText(new RegExp(`You blocked ${aName}`))
    .first()
    .waitFor({ timeout: 15000 });
  await pb.goto(`${env.base}/chats`);
  await pb.getByRole("radiogroup", { name: "Chats or requests" }).waitFor({ timeout: 20000 });
  await pb.waitForLoadState("networkidle");
  const row = pb.getByRole("link", { name: new RegExp(`^${aName}(,|$)`) });
  if ((await row.count()) > 0) throw new Error("the blocked DM is still in B's list");
});

await r.step("block stops delivery: A's next message is refused and never reaches B", async () => {
  // A's page still has the composer it loaded before the block.
  await send(pa, msg5);
  await pa
    .getByText("You can't send messages in this conversation.")
    .first()
    .waitFor({ timeout: 20000 });
  await shot(pa, "msg-12-blocked-sender");
  // The draft stays in the composer or the gate replaced it; it is never in the history.
  if ((await bubble(pa, msg5).count()) > 0) throw new Error("the refused message shows as sent");
  await pb.goto(`${env.base}${convPath}`);
  await pb.waitForLoadState("networkidle");
  await pb.waitForTimeout(1500);
  if ((await pb.getByText(msg5).count()) > 0)
    throw new Error("B received a message after the block");
  if ((await pb.getByText(msg4).count()) > 0)
    throw new Error("B still sees A's messages after the block");
  await shot(pb, "msg-13-blocked-blocker");
  // A, reloaded: the composer is gone, the closed state is shown.
  await pa.reload();
  await pa.getByText("You can't send messages in this conversation.").waitFor({ timeout: 20000 });
  if (await composer(pa).isVisible()) throw new Error("A can still type after the block");
  await assertNoHorizontalScroll(pa, "closed conversation");
});

await r.step("B unblocks A (cleanup)", async () => {
  await pb.goto(`${env.base}/you/blocked`);
  const unblock = pb.getByRole("button", { name: `Unblock ${aName}` });
  await unblock.waitFor({ timeout: 15000 });
  await unblock.click();
  await pb.getByRole("dialog").getByRole("button", { name: "Unblock" }).click();
  await pb.getByText("No one blocked").waitFor({ timeout: 10000 });
});

await r.step("plan chat from A's plan page", async () => {
  if (!eventId) {
    console.log("NOTE messaging / plan chat: no event id (run 03-plan.mjs first); skipped");
    return;
  }
  await pa.goto(`${env.base}/events/${eventId}`);
  await pa.getByRole("button", { name: "Plan chat" }).click({ timeout: 20000 });
  await pa.waitForURL((u) => /^\/chats\/[0-9a-f-]{36}$/.test(u.pathname), { timeout: 20000 });
  await composer(pa).or(pa.getByRole("status")).first().waitFor({ timeout: 20000 });
  await shot(pa, "msg-14-plan-chat");
  await assertNoHorizontalScroll(pa, "plan chat");
});

for (const [who, ctx] of [
  ["A", A],
  ["B", B],
]) {
  console.log(
    ctx.problems.length
      ? `PROBLEMS (messaging ${who}):\n  ${[...new Set(ctx.problems)].join("\n  ")}`
      : `PROBLEMS (messaging ${who}): none`,
  );
}
const failed = r.done();
await A.context.close();
await B.context.close();
await browser.close();
process.exit(failed ? 1 : 0);
