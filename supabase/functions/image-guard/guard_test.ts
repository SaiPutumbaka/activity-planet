// deno test --allow-read supabase/functions/image-guard
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import { type GuardDeps, MAX_BYTES, parseGuardRequest, runCheck, runSweep } from "./guard.ts";

const base = await Deno.readFile(new URL("./fixtures/base.jpg", import.meta.url));
const webp = await Deno.readFile(new URL("./fixtures/base.webp", import.meta.url));

interface Fake extends GuardDeps {
  calls: { name: string; args: Record<string, unknown> }[];
  removed: { bucket: string; paths: string[] }[];
}

function fake(opts: {
  bytes: Uint8Array | null | "too_large";
  outcome?: string;
  purge?: { id: string; bucket: string; path: string }[];
}): Fake {
  let purge = [...(opts.purge ?? [])];
  const f: Fake = {
    calls: [],
    removed: [],
    rpc(name, args) {
      f.calls.push({ name, args });
      if (name === "image_guard_record")
        return Promise.resolve({ outcome: opts.outcome ?? "ok", copies: 1 });
      if (name === "image_guard_purge_list") return Promise.resolve(purge);
      if (name === "image_guard_mark_purged") {
        const ids = args.p_ids as string[];
        purge = purge.filter((p) => !ids.includes(p.id));
        return Promise.resolve(ids.length);
      }
      return Promise.reject(new Error(`unexpected ${name}`));
    },
    download: () => Promise.resolve(opts.bytes),
    remove(bucket, paths) {
      f.removed.push({ bucket, paths });
      return Promise.resolve();
    },
  };
  return f;
}

const uid = "6f1c1c1e-5b8e-4a3e-9d0a-3d1f2b4c5a6e";

Deno.test("parseGuardRequest accepts check and sweep only, with safe object names", () => {
  assertEquals(parseGuardRequest({ op: "sweep" }), { op: "sweep" });
  assertEquals(parseGuardRequest({ op: "check", bucket: "avatars", path: `${uid}/1.jpg` }), {
    op: "check",
    bucket: "avatars",
    path: `${uid}/1.jpg`,
  });
  for (const bad of [
    null,
    "x",
    {},
    { op: "delete" },
    { op: "check", bucket: "Avatars", path: "a.jpg" },
    { op: "check", bucket: "avatars", path: "../x.jpg" },
    { op: "check", bucket: "avatars", path: "a/../b.jpg" },
    { op: "check", bucket: "avatars", path: "/a.jpg" },
    { op: "check", bucket: "avatars", path: "a b.jpg" },
    { op: "check", bucket: "avatars", path: "a".repeat(401) },
    { op: "check", bucket: "avatars" },
  ]) {
    assertEquals(parseGuardRequest(bad), null, JSON.stringify(bad));
  }
});

Deno.test("check: a JPEG is hashed and recorded; nothing is deleted when allowed", async () => {
  const f = fake({ bytes: base });
  const r = await runCheck(f, { bucket: "avatars", path: `${uid}/1.jpg` });
  assertEquals(r, { outcome: "ok", copies: 1, deleted: 0 });
  assertEquals(f.calls.length, 1);
  const args = f.calls[0]!.args;
  assertEquals(args.p_status, "hashed");
  assertEquals(args.p_phash, "cd73ca7ac411565a");
  assertEquals(args.p_dhash, "fefcf9797d7f071f");
  assert(/^[0-9a-f]{64}$/.test(String(args.p_sha256)));
  assertEquals(f.removed, []);
});

Deno.test("check: a blocked match is deleted in the same run", async () => {
  const f = fake({
    bytes: base,
    outcome: "blocked",
    purge: [
      { id: "i1", bucket: "avatars", path: `${uid}/1.jpg` },
      { id: "i2", bucket: "avatars", path: `${uid}/0.jpg` },
    ],
  });
  const r = await runCheck(f, { bucket: "avatars", path: `${uid}/1.jpg` });
  assertEquals(r.outcome, "blocked");
  assertEquals(r.deleted, 2);
  assertEquals(f.removed, [{ bucket: "avatars", paths: [`${uid}/1.jpg`, `${uid}/0.jpg`] }]);
});

Deno.test(
  "check: unreadable, too large and missing objects are reported without hashes",
  async () => {
    for (const [bytes, status] of [
      [webp, "unreadable"],
      ["too_large", "unreadable"],
      [null, "missing"],
    ] as const) {
      const f = fake({ bytes, outcome: status });
      await runCheck(f, { bucket: "avatars", path: `${uid}/1.jpg` });
      const args = f.calls[0]!.args;
      assertEquals(args.p_status, status);
      assertEquals(args.p_sha256, undefined);
    }
    assert(MAX_BYTES >= 2 * 1024 * 1024);
  },
);

Deno.test("sweep: groups by bucket and stops when the list is empty", async () => {
  const f = fake({
    bytes: null,
    purge: [
      { id: "a", bucket: "avatars", path: "x/1.jpg" },
      { id: "b", bucket: "covers", path: "y/2.jpg" },
    ],
  });
  assertEquals(await runSweep(f), 2);
  assertEquals(f.removed.length, 2);
  assertEquals(f.calls.filter((c) => c.name === "image_guard_purge_list").length, 1);
});
