// Shared helpers for the browser smoke flows (plain Node + Playwright, not part of `pnpm test`).
// Credentials and paths come only from env vars; nothing here prints user rows or secrets.
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

const require = createRequire(import.meta.url);

export const env = {
  base: process.env.E2E_BASE_URL || "http://localhost:4173",
  email: process.env.E2E_EMAIL,
  password: process.env.E2E_PASSWORD,
  emailB: process.env.E2E_EMAIL_B,
  passwordB: process.env.E2E_PASSWORD_B,
  outDir: process.env.E2E_QA_DIR || join(process.cwd(), "e2e-output"),
};

/** Exit 0 with a note when the flow cannot run here (no credentials, no Playwright). */
export function skipUnless(cond, why) {
  if (!cond) {
    console.log(`SKIP: ${why}`);
    process.exit(0);
  }
}

export function loadPlaywright() {
  for (const name of ["playwright", "/opt/node-tools/node_modules/playwright"]) {
    try {
      return require(name);
    } catch {
      /* try the next */
    }
  }
  return null;
}

export const VIEWPORTS = {
  phone: { width: 390, height: 844 },
  desktop: { width: 1280, height: 800 },
};

/**
 * The width a single-width flow runs at: the phone unless E2E_VIEWPORT=desktop. Flows that
 * already walk both widths (02, 05, 08, 09, 11) ignore it.
 */
export const MAIN_VIEWPORT =
  process.env.E2E_VIEWPORT === "desktop" ? VIEWPORTS.desktop : VIEWPORTS.phone;

/**
 * A browser context per viewport, with console errors, page errors and failed requests collected
 * (only their messages and URLs without query strings, so tokens never reach the output).
 */
export async function openContext(browser, viewport = VIEWPORTS.phone) {
  const context = await browser.newContext({ viewport, serviceWorkers: "block" });
  const page = await context.newPage();
  const problems = [];
  const strip = (u) => String(u).split("?")[0];
  page.on("console", (m) => {
    if (m.type() === "error") problems.push(`console: ${m.text().slice(0, 300)}`);
  });
  page.on("pageerror", (e) => problems.push(`pageerror: ${String(e.message).slice(0, 300)}`));
  page.on("response", (r) => {
    if (r.status() >= 400)
      problems.push(`http ${r.status()}: ${r.request().method()} ${strip(r.url())}`);
  });
  return { context, page, problems };
}

/** Fails when the page scrolls sideways (a broken layout at that width). */
export async function assertNoHorizontalScroll(page, label) {
  const over = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  if (over > 1) throw new Error(`${label}: page scrolls sideways by ${over}px`);
}

export async function shot(page, name) {
  mkdirSync(env.outDir, { recursive: true });
  await page.screenshot({ path: join(env.outDir, `${name}.png`), fullPage: false });
}

export async function signIn(page, email, password) {
  await page.goto(`${env.base}/auth/sign-in`);
  await page.getByLabel("Email").fill(email);
  await page.getByLabel("Password").fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForURL((u) => !u.pathname.startsWith("/auth/"), { timeout: 20000 });
}

/** Runs named steps, records pass/fail per step, never stops at the first failure. */
export function makeRunner(flowName) {
  const results = [];
  return {
    results,
    async step(name, fn) {
      try {
        await fn();
        results.push({ flow: flowName, step: name, ok: true });
        console.log(`PASS ${flowName} / ${name}`);
      } catch (e) {
        results.push({
          flow: flowName,
          step: name,
          ok: false,
          error: String(e.message).split("\n")[0],
        });
        console.log(
          `FAIL ${flowName} / ${name}: ${String(e.message).split("\n")[0].slice(0, 300)}`,
        );
      }
    },
    done() {
      const failed = results.filter((r) => !r.ok).length;
      console.log(`${flowName}: ${results.length - failed} passed, ${failed} failed`);
      return failed;
    },
  };
}
