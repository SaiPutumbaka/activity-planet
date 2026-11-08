import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

/**
 * Launch audit M10: the Report-Only CSP in vercel.json allows the one inline script in
 * index.html (the theme bootstrap) by its hash, so editing that script must update the hash.
 */
const root = fileURLToPath(new URL("../../../", import.meta.url));
const html = readFileSync(`${root}index.html`, "utf8");
const vercel = JSON.parse(readFileSync(`${root}vercel.json`, "utf8")) as {
  rewrites: { source: string }[];
  headers: { source: string; headers: { key: string; value: string }[] }[];
};
const all = vercel.headers.find((h) => h.source === "/(.*)")?.headers ?? [];
const header = (key: string) => all.find((h) => h.key === key)?.value ?? "";

describe("app security headers", () => {
  it("allows every inline script by its hash", () => {
    const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1] ?? "");
    expect(scripts.length).toBeGreaterThan(0);
    for (const s of scripts) {
      const hash = createHash("sha256").update(s).digest("base64");
      expect(header("Content-Security-Policy-Report-Only")).toContain(`'sha256-${hash}'`);
    }
  });

  it("enforces the directives that cannot break the app", () => {
    const csp = header("Content-Security-Policy");
    for (const d of ["object-src 'none'", "base-uri 'self'", "frame-ancestors 'none'"]) {
      expect(csp).toContain(d);
    }
    expect(header("Permissions-Policy")).toContain("microphone=()");
  });

  it("never loads Google Fonts", () => {
    expect(html).not.toContain("fonts.googleapis.com");
  });

  it("does not answer /api/ with the app shell", () => {
    expect(vercel.rewrites.every((r) => r.source.includes("(?!api/)"))).toBe(true);
  });
});
