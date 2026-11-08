// finishDeletion with a fake Supabase client (no network): the evidence hold copies photos into
// legal-hold before any original is deleted, a failed copy deletes nothing, an unheld account is
// cleaned up directly, and internal error messages never reach the result.
import { assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import { finishDeletion, purgeLegalHolds } from "./finish.ts";

const UID = "11111111-2222-4333-8444-555555555555";

interface Fake {
  admin: SupabaseClient;
  log: string[];
}

function fake(opts: {
  hold?: boolean;
  failUpload?: boolean;
  completed?: boolean;
  authError?: boolean;
}): Fake {
  const log: string[] = [];
  const files: Record<string, { id: string | null; name: string }[]> = {
    [`avatars:${UID}`]: [{ id: "a", name: "photo.webp" }],
    [`chat-images:${UID}`]: [{ id: null, name: "conv1" }],
    [`chat-images:${UID}/conv1`]: [{ id: "c", name: "img.jpg" }],
  };
  const table = (name: string) => {
    const q: Record<string, unknown> = {};
    const result = () => {
      if (name === "account_deletions")
        return { data: { completed_at: opts.completed ? "2026-11-01" : null }, error: null };
      if (name === "profiles") return { data: { status: "deleted" }, error: null };
      return { data: null, error: null };
    };
    Object.assign(q, {
      select: () => q,
      eq: () => q,
      maybeSingle: () => Promise.resolve(result()),
      delete: () => {
        log.push(`delete:${name}`);
        return q;
      },
      update: () => {
        log.push(`update:${name}`);
        return q;
      },
      upsert: () => Promise.resolve({ error: null }),
      then: (r: (v: unknown) => unknown) => r({ error: null }),
    });
    return q;
  };
  const storage = {
    from: (bucket: string) => ({
      list: (prefix: string) =>
        Promise.resolve({ data: files[`${bucket}:${prefix}`] ?? [], error: null }),
      download: (path: string) => {
        log.push(`download:${bucket}/${path}`);
        return Promise.resolve({ data: new Blob(["x"], { type: "image/jpeg" }), error: null });
      },
      upload: (path: string) => {
        log.push(`upload:${bucket}/${path}`);
        return Promise.resolve({ error: opts.failUpload ? { message: "boom" } : null });
      },
      remove: (paths: string[]) => {
        log.push(`remove:${bucket}:${paths.join(",")}`);
        return Promise.resolve({ error: null });
      },
    }),
  };
  const rpc = (name: string, args: Record<string, unknown>) => {
    log.push(`rpc:${name}`);
    if (name === "legal_hold_for")
      return Promise.resolve({ data: opts.hold ? "2027-11-08" : null, error: null });
    if (name === "legal_hold_saved") {
      const p = String(args.p_source_path);
      return Promise.resolve({
        data: `${UID}/${args.p_source_bucket}/${p.slice(37)}`,
        error: null,
      });
    }
    if (name === "legal_hold_purge_list")
      return Promise.resolve({
        data: [{ id: "h1", path: `${UID}/avatars/photo.webp` }],
        error: null,
      });
    if (name === "legal_hold_purged") return Promise.resolve({ data: 1, error: null });
    return Promise.resolve({ data: [], error: null });
  };
  const admin = {
    from: table,
    storage,
    rpc,
    auth: {
      admin: {
        deleteUser: () =>
          Promise.resolve({
            error: opts.authError
              ? { name: "AuthApiError", message: "internal detail x@y.z" }
              : null,
          }),
      },
    },
  } as unknown as SupabaseClient;
  return { admin, log };
}

Deno.test(
  "a held account's photos are copied to legal-hold before any original is removed",
  async () => {
    const f = fake({ hold: true });
    const r = await finishDeletion({ admin: f.admin, stripe: null }, UID);
    assertEquals(r, { ok: true, held: 2 });
    const firstRemove = f.log.findIndex((l) => l.startsWith("remove:"));
    const uploads = f.log
      .map((l, i) => [l, i] as const)
      .filter(([l]) => l.startsWith("upload:legal-hold/"));
    assertEquals(
      uploads.map(([l]) => l),
      [
        `upload:legal-hold/${UID}/avatars/photo.webp`,
        `upload:legal-hold/${UID}/chat-images/conv1/img.jpg`,
      ],
    );
    assertEquals(
      uploads.every(([, i]) => i < firstRemove),
      true,
    );
    assertEquals(f.log.includes("update:account_deletions"), true);
  },
);

Deno.test("a failed legal-hold copy deletes nothing", async () => {
  const f = fake({ hold: true, failUpload: true });
  const r = await finishDeletion({ admin: f.admin, stripe: null }, UID);
  assertEquals(r, { ok: false, error: "legal_hold_copy_failed", status: 500 });
  assertEquals(
    f.log.some((l) => l.startsWith("remove:")),
    false,
  );
});

Deno.test("an account with no hold is cleaned up without copies", async () => {
  const f = fake({});
  const r = await finishDeletion({ admin: f.admin, stripe: null }, UID);
  assertEquals(r, { ok: true });
  assertEquals(
    f.log.some((l) => l.startsWith("upload:legal-hold")),
    false,
  );
  assertEquals(f.log.includes(`remove:avatars:${UID}/photo.webp`), true);
  assertEquals(f.log.includes(`remove:chat-images:${UID}/conv1/img.jpg`), true);
});

Deno.test("an auth error returns a code only", async () => {
  const f = fake({ authError: true });
  const r = await finishDeletion({ admin: f.admin, stripe: null }, UID);
  assertEquals(r, { ok: false, error: "auth_delete_failed", status: 500 });
  assertEquals(JSON.stringify(r).includes("x@y.z"), false);
});

Deno.test("a completed deletion is not run again", async () => {
  const f = fake({ completed: true });
  const r = await finishDeletion({ admin: f.admin, stripe: null }, UID);
  assertEquals(r, { ok: true, alreadyCompleted: true });
  assertEquals(f.log.length, 0);
});

Deno.test("expired legal-hold copies are removed and stamped", async () => {
  const f = fake({});
  assertEquals(await purgeLegalHolds(f.admin), 1);
  assertEquals(f.log.includes(`remove:legal-hold:${UID}/avatars/photo.webp`), true);
});
