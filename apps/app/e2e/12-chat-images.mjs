// Chat photos (migrations 71 to 74, meta.chat_images on): A sends B a small plain landscape
// picture drawn in the browser (sky, hills, a sun; nothing else is ever uploaded). A sees it at
// once as "Photo is being checked"; B never sees it until image-guard's pHash check and the
// Sightengine classifier pass, then it shows for both; B reports it, which files the evidence
// row the next image-guard sweep copies into chat-evidence (checked on staging with counts, not
// here). Needs the Sightengine keys on the project. Two accounts at 390x844; reuses the DM of
// 07-messaging.mjs (a request is sent and accepted when there is none). Output names steps
// only, never user rows.
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

skipUnless(
  env.email && env.password && env.emailB && env.passwordB,
  "E2E_EMAIL/_B and E2E_PASSWORD/_B are not set",
);
const pw = loadPlaywright();
skipUnless(pw, "playwright is not installed");

const browser = await pw.chromium.launch();
const A = await openContext(browser, MAIN_VIEWPORT);
const B = await openContext(browser, MAIN_VIEWPORT);
const pa = A.page;
const pb = B.page;
const r = makeRunner("chat-images");
const stamp = Date.now().toString(36);
const VERDICT_MS = Number(process.env.E2E_VERDICT_MS || 240000);

let aName = "";
let bName = "";
let bHandle = "";
let convPath = "";

async function whoAmI(page) {
  await page.goto(`${env.base}/you`);
  const sec = page.locator("main section").first();
  await sec.locator("p").nth(1).waitFor({ timeout: 20000 });
  const name = (await sec.locator("p").nth(0).innerText()).trim();
  const handle = (await sec.locator("p").nth(1).innerText()).trim().replace(/^@/, "");
  return { name, handle };
}

/** A plain landscape JPEG drawn in the browser: sky, two hills, a sun. */
async function landscapeJpeg() {
  const p = await browser.newPage({ viewport: { width: 640, height: 400 } });
  await p.setContent(`<body style="margin:0"><svg width="640" height="400" xmlns="http://www.w3.org/2000/svg">
    <defs><linearGradient id="s" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#7dd3fc"/><stop offset="1" stop-color="#e0f2fe"/></linearGradient></defs>
    <rect width="640" height="400" fill="url(#s)"/>
    <circle cx="500" cy="90" r="42" fill="#fde047"/>
    <path d="M0 300 Q160 190 320 290 T640 260 V400 H0Z" fill="#4ade80"/>
    <path d="M0 340 Q200 270 400 340 T640 330 V400 H0Z" fill="#16a34a"/>
  </svg></body>`);
  const buf = await p.screenshot({ type: "jpeg", quality: 85 });
  await p.close();
  return buf;
}

const composer = (page) => page.getByRole("textbox", { name: "Message" });
const history = (page) => page.getByRole("list", { name: "Conversation history" });

await r.step("sign in both accounts", async () => {
  await signIn(pa, env.email, env.password);
  await signIn(pb, env.emailB, env.passwordB);
});

await r.step("read names and handles", async () => {
  const a = await whoAmI(pa);
  const b = await whoAmI(pb);
  aName = a.name;
  bName = b.name;
  bHandle = b.handle;
  if (!aName || !bName || !bHandle) throw new Error("could not read the You tab");
});

await r.step("A opens the DM with B (a request is sent and accepted when needed)", async () => {
  await pa.goto(`${env.base}/chats/new`);
  await pa.getByLabel("Search by handle").fill(bHandle);
  await pa.getByRole("button", { name: `Message ${bName}` }).click({ timeout: 20000 });
  await pa.waitForURL((u) => /^\/chats\/[0-9a-f-]{36}$/.test(u.pathname), { timeout: 20000 });
  convPath = new URL(pa.url()).pathname;
  await composer(pa).or(pa.getByRole("status")).first().waitFor({ timeout: 20000 });
  const request = await pa
    .getByText("This is a message request")
    .isVisible()
    .catch(() => false);
  if (request) {
    await composer(pa).fill(`Hello for the photo check ${stamp}`);
    await composer(pa).press("Enter");
    await pb.goto(`${env.base}${convPath}`);
    await pb.getByRole("button", { name: "Accept" }).click({ timeout: 20000 });
    await composer(pb).waitFor({ timeout: 15000 });
    await pa.reload();
  }
  await composer(pa).waitFor({ timeout: 20000 });
});

await r.step("the photo button shows while chat images are on", async () => {
  await pa.getByRole("button", { name: "Send a photo" }).waitFor({ timeout: 20000 });
  await shot(pa, "chatimg-01-composer");
  await assertNoHorizontalScroll(pa, "conversation with the photo button");
});

let before = 0;
let aPendingBefore = 0;
const pendingLabels = (page) => history(page).getByText("Photo is being checked");
await r.step("A sends a plain landscape photo; A sees it as being checked", async () => {
  await pb.goto(`${env.base}${convPath}`);
  await composer(pb).waitFor({ timeout: 20000 });
  before = await history(pb).getByRole("img", { name: "Photo" }).count();
  aPendingBefore = await pendingLabels(pa).count();
  await pa.locator('input[type="file"][accept="image/*"]').setInputFiles({
    name: "landscape.jpg",
    mimeType: "image/jpeg",
    buffer: await landscapeJpeg(),
  });
  // The pending label shows on A's own copy until both checks pass (it can clear quickly).
  const pending = await pendingLabels(pa)
    .nth(aPendingBefore)
    .waitFor({ timeout: 20000 })
    .then(() => true)
    .catch(() => false);
  await shot(pa, "chatimg-02-sender-pending");
  if (!pending)
    console.log("NOTE chat-images / pending: the verdict came before the label was seen");
});

await r.step("B does not see it while it is being checked", async () => {
  // B looks first, then A's copy is read again: when A's copy is still labelled after B's look,
  // B's look happened before the verdict, so B must not have had the new photo. When the verdict
  // came first nothing is proven and the step fails as inconclusive (run the flow again).
  await pb.reload();
  await composer(pb).waitFor({ timeout: 20000 });
  const early = await history(pb).getByRole("img", { name: "Photo" }).count();
  await pa.reload();
  await composer(pa).waitFor({ timeout: 20000 });
  await history(pa).getByRole("listitem").first().waitFor({ timeout: 20000 });
  const stillPending = (await pendingLabels(pa).count()) > aPendingBefore;
  if (stillPending && early > before)
    throw new Error("B saw the new photo while A's copy was still being checked");
  if (!stillPending)
    throw new Error("inconclusive: the verdict came before B's first look; run the flow again");
  await shot(pb, "chatimg-03a-recipient-pending");
});

await r.step("B sees it once it passes", async () => {
  const t0 = Date.now();
  let now = before;
  while (now <= before && Date.now() - t0 < VERDICT_MS) {
    await pb.waitForTimeout(10000);
    await pb.reload();
    await composer(pb).waitFor({ timeout: 20000 });
    now = await history(pb).getByRole("img", { name: "Photo" }).count();
  }
  if (now <= before) {
    const label = await history(pb)
      .getByText(/Photo is being checked|can't be shared/)
      .count();
    throw new Error(`no visible photo for B after ${VERDICT_MS / 1000}s (labels: ${label})`);
  }
  console.log(
    `NOTE chat-images / verdict: visible for B after about ${Math.round((Date.now() - t0) / 1000)}s`,
  );
  await history(pb).getByRole("img", { name: "Photo" }).first().scrollIntoViewIfNeeded();
  await shot(pb, "chatimg-03-recipient-visible");
});

await r.step("A's copy is no longer labelled once it passed", async () => {
  await pa.reload();
  await composer(pa).waitFor({ timeout: 20000 });
  await history(pa).getByRole("img", { name: "Photo" }).first().waitFor({ timeout: 20000 });
  await shot(pa, "chatimg-04-sender-visible");
});

await r.step("B reports the photo (the evidence row for the copy)", async () => {
  await pb
    .getByRole("button", { name: new RegExp(`^Options for the message from ${aName}`) })
    .first()
    .click({ timeout: 20000 });
  const dialog = pb.getByRole("dialog");
  await dialog.getByRole("button", { name: "Report message" }).click();
  await dialog.getByRole("radio").first().check();
  await dialog.getByLabel("Details (optional)").fill("QA e2e photo report, please ignore.");
  await shot(pb, "chatimg-05-report");
  await dialog.getByRole("button", { name: "Send report" }).click();
  await pb
    .getByText(/A moderator will look at it|already reported/)
    .first()
    .waitFor({ timeout: 15000 });
});

for (const [who, ctx] of [
  ["A", A],
  ["B", B],
]) {
  console.log(
    ctx.problems.length
      ? `PROBLEMS (chat-images ${who}):\n  ${[...new Set(ctx.problems)].join("\n  ")}`
      : `PROBLEMS (chat-images ${who}): none`,
  );
}
const failed = r.done();
await A.context.close();
await B.context.close();
await browser.close();
process.exit(failed ? 1 : 0);
