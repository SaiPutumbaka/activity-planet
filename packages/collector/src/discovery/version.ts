// The probe code's hash (migration 47): the gate's pass is good only for the code that earned it.
// Every TypeScript file under src/ (the probe reads through the collector's own fetcher, parsers
// and filters) and the discovery and denylist data, by path, sha256, first 32 hex. A change to any
// of them needs a new Atlanta gate run before the probe may read candidates again.

import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../../", import.meta.url));

function files(dir: string): string[] {
  const out: string[] = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...files(p));
    else if (e.name.endsWith(".ts")) out.push(p);
  }
  return out;
}

export function probeHash(root: string = ROOT): string {
  const paths = [
    ...files(join(root, "src")),
    join(root, "data", "discovery.json"),
    join(root, "data", "denylist.json"),
  ]
    .map((p) => relative(root, p).split("\\").join("/"))
    .sort();
  const h = createHash("sha256");
  for (const p of paths) {
    h.update(p);
    h.update("\0");
    // Line endings do not change the code.
    h.update(readFileSync(join(root, p), "utf8").replace(/\r\n/g, "\n"));
    h.update("\0");
  }
  return h.digest("hex").slice(0, 32);
}
