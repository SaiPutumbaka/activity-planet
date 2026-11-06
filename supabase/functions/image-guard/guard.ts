// image-guard: request parsing and the check and sweep runs (fake I/O in guard_test.ts). The
// classify run (chat images, migration 71) is in classify.ts.
//
//   check  download one Storage object with the service role, hash it (hash.ts; decode.ts for
//          JPEG and PNG) and hand the hashes to image_guard_record, which decides: allowed,
//          blocked (matches a removed image, or a moderator asked for it), unreadable or missing.
//          Then a sweep, so a blocked object is deleted in the same run.
//   sweep  delete every object image_guard_purge_list returns through the Storage API and
//          stamp them with image_guard_mark_purged.
//
// Nothing is written but hashes and statuses. The bytes are held in memory for one request and
// never logged, stored or returned.
import { decodeImage } from "./decode.ts";
import { hashPixels, sha256Hex } from "./hash.ts";

/** Largest object downloaded (the avatars bucket allows 2 MiB; older projects 5 MiB). */
export const MAX_BYTES = 6 * 1024 * 1024;

export type GuardRequest =
  | { op: "check"; bucket: string; path: string }
  | { op: "classify"; bucket: "chat-images"; path: string }
  | { op: "sweep" };

const BUCKET = /^[a-z0-9][a-z0-9_-]{0,62}$/;
const PATH = /^[A-Za-z0-9._~-]+(\/[A-Za-z0-9._~-]+)*$/;

/** The request body, or null when it is not one this function accepts. */
export function parseGuardRequest(body: unknown): GuardRequest | null {
  if (!body || typeof body !== "object") return null;
  const b = body as Record<string, unknown>;
  if (b.op === "sweep") return { op: "sweep" };
  if (b.op !== "check" && b.op !== "classify") return null;
  const { bucket, path } = b;
  if (typeof bucket !== "string" || typeof path !== "string") return null;
  if (!BUCKET.test(bucket) || path.length > 400 || !PATH.test(path)) return null;
  if (path.split("/").some((seg) => seg === "." || seg === "..")) return null;
  // Migration 71: only chat images are classified.
  if (b.op === "classify")
    return bucket === "chat-images" ? { op: "classify", bucket, path } : null;
  return { op: "check", bucket, path };
}

export interface GuardDeps {
  rpc(name: string, args: Record<string, unknown>): Promise<unknown>;
  /** The object's bytes, null when it does not exist, "too_large" over MAX_BYTES. */
  download(bucket: string, path: string): Promise<Uint8Array | null | "too_large">;
  /** Deletes objects in one bucket; missing ones are not an error. */
  remove(bucket: string, paths: string[]): Promise<void>;
  /** Migration 72: writes (or overwrites) one JPEG object with the service role. */
  upload(bucket: string, path: string, bytes: Uint8Array): Promise<void>;
}

export type Outcome = "ok" | "blocked" | "unreadable" | "missing";

export interface CheckResult {
  outcome: Outcome;
  copies: number;
  deleted: number;
}

export async function runCheck(
  deps: GuardDeps,
  req: { bucket: string; path: string },
): Promise<CheckResult> {
  const bytes = await deps.download(req.bucket, req.path);
  let args: Record<string, unknown>;
  if (bytes === null) {
    args = { p_bucket: req.bucket, p_path: req.path, p_status: "missing" };
  } else {
    const px = bytes === "too_large" ? null : decodeImage(bytes);
    if (bytes === "too_large" || !px) {
      args = { p_bucket: req.bucket, p_path: req.path, p_status: "unreadable" };
    } else {
      const { phash, dhash } = hashPixels(px);
      args = {
        p_bucket: req.bucket,
        p_path: req.path,
        p_status: "hashed",
        p_sha256: await sha256Hex(bytes),
        p_phash: phash,
        p_dhash: dhash,
      };
    }
  }
  const res = (await deps.rpc("image_guard_record", args)) as {
    outcome?: string;
    copies?: number;
  } | null;
  const outcome = (res?.outcome ?? "ok") as Outcome;
  const deleted = outcome === "blocked" || outcome === "unreadable" ? await runSweep(deps) : 0;
  return { outcome, copies: Number(res?.copies ?? 0), deleted };
}

/**
 * Migration 72: copies reported chat photos into the private chat-evidence bucket
 * (<report id>.jpg) before anything deletes the original, at most 25 a run. Returns how many
 * were copied; a missing original is recorded as such (image_evidence_missing_at, migration 73)
 * so it is not asked again.
 */
export async function runEvidenceCopy(deps: GuardDeps): Promise<number> {
  const list = ((await deps.rpc("chat_image_evidence_list", { p_limit: 25 })) ?? []) as {
    report_id: string;
    path: string;
  }[];
  if (!Array.isArray(list)) return 0;
  let copied = 0;
  for (const row of list) {
    const bytes = await deps.download("chat-images", row.path);
    if (bytes === null || bytes === "too_large") {
      await deps.rpc("chat_image_evidence_saved", { p_report: row.report_id, p_path: null });
      continue;
    }
    const target = `${row.report_id}.jpg`;
    await deps.upload("chat-evidence", target, bytes);
    await deps.rpc("chat_image_evidence_saved", { p_report: row.report_id, p_path: target });
    copied++;
  }
  return copied;
}

/**
 * Deletes what waits for deletion (at most 4 pages of 50): blocked and unreadable objects
 * (image_guard_purge_list), then (migration 72) chat photos their sender or a host deleted, chat
 * uploads never sent, and evidence copies whose report record is gone (chat_image_purge_list).
 * Reported chat photos are copied first (runEvidenceCopy). Returns how many were deleted.
 */
export async function runSweep(deps: GuardDeps): Promise<number> {
  await runEvidenceCopy(deps);
  let deleted = 0;
  for (let page = 0; page < 4; page++) {
    const list = ((await deps.rpc("image_guard_purge_list", { p_limit: 50 })) ?? []) as {
      id: string;
      bucket: string;
      path: string;
    }[];
    if (!Array.isArray(list) || list.length === 0) break;
    const byBucket = new Map<string, { ids: string[]; paths: string[] }>();
    for (const row of list) {
      const g = byBucket.get(row.bucket) ?? { ids: [], paths: [] };
      g.ids.push(row.id);
      g.paths.push(row.path);
      byBucket.set(row.bucket, g);
    }
    const done: string[] = [];
    for (const [bucket, g] of byBucket) {
      await deps.remove(bucket, g.paths);
      done.push(...g.ids);
    }
    deleted += Number((await deps.rpc("image_guard_mark_purged", { p_ids: done })) ?? 0);
    if (list.length < 50) break;
  }
  for (let page = 0; page < 4; page++) {
    const list = ((await deps.rpc("chat_image_purge_list", { p_limit: 50 })) ?? []) as {
      bucket: string;
      path: string;
    }[];
    if (!Array.isArray(list) || list.length === 0) break;
    const byBucket = new Map<string, string[]>();
    for (const row of list)
      byBucket.set(row.bucket, [...(byBucket.get(row.bucket) ?? []), row.path]);
    for (const [bucket, paths] of byBucket) {
      if (bucket !== "chat-images" && bucket !== "chat-evidence") continue;
      await deps.remove(bucket, paths);
      deleted += paths.length;
    }
    if (list.length < 50) break;
  }
  return deleted;
}
