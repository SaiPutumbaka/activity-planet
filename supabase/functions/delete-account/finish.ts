// The cleanup half of an account deletion (D-031), shared by the member's own call and the
// sweep (migration 77). request_account_deletion() has already, in one transaction, written the
// ledger row, tombstoned the profile, removed private data and memberships and banned the user.
// With the service role this:
//   0. migration 77, the evidence hold: when the ledger row carries legal_hold_until (a
//      child-safety or NCII report or takedown of the last year concerns the account), every
//      avatars/<uid>/ and chat-images/<uid>/ object is copied into the private legal-hold bucket
//      and recorded (legal_hold_saved) before any original is deleted; a copy that cannot be made
//      stops the run, so the evidence is never lost;
//   1. removes the avatar files (avatars/<uid>/, photos and covers), copies every reported chat
//      photo still pending to chat-evidence (migration 73) and removes chat-images/<uid>/;
//   2. drops provider tokens (Apple revocation is a TODO until Capacitor ships);
//   3. Stripe (migration 60): closes the connected account when the balance allows, else queues
//      a close_account job; without STRIPE_SECRET_KEY nothing is sent;
//   4. soft-deletes the auth user (frees the email and identities, ends every session);
//   5. stamps completed_at on the ledger row.
// Every step is idempotent, so a run that stopped halfway is finished by the next one. Errors
// are codes only (the logs are public); the caller decides what the client sees.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import { createStripe, stripeErrorName, type Stripe } from "../_shared/stripe.ts";

export type FinishResult =
  | { ok: true; alreadyCompleted?: boolean; held?: number }
  | { ok: false; error: string; status: number };

export interface FinishDeps {
  admin: SupabaseClient;
  stripe: Stripe | null;
  now?: () => Date;
}

/** The HTTP status a Storage error carries, when it carries one. */
export function storageStatus(error: unknown): number | null {
  if (!error || typeof error !== "object") return null;
  const e = error as { status?: unknown; statusCode?: unknown };
  const raw = e.status ?? e.statusCode;
  const n = typeof raw === "number" ? raw : typeof raw === "string" ? Number(raw) : NaN;
  return Number.isFinite(n) ? n : null;
}

const LIST_PAGE = 1000;

function fail(error: string, status = 500): FinishResult {
  return { ok: false, error, status };
}

export function stripeFromEnv(key: string | undefined): Stripe | null {
  return key ? createStripe(key) : null;
}

export async function finishDeletion(deps: FinishDeps, userId: string): Promise<FinishResult> {
  const { admin } = deps;
  const now = deps.now ?? (() => new Date());

  // Consent happened in the database.
  const [ledgerResult, profileResult] = await Promise.all([
    admin.from("account_deletions").select("completed_at").eq("user_id", userId).maybeSingle(),
    admin.from("profiles").select("status").eq("id", userId).maybeSingle(),
  ]);
  if (ledgerResult.error || profileResult.error) return fail("lookup_failed");
  if (!ledgerResult.data || profileResult.data?.status !== "deleted") {
    return fail("deletion_not_requested", 409);
  }
  if (ledgerResult.data.completed_at) return { ok: true, alreadyCompleted: true };

  // Every entry under a folder: storage.list returns at most `limit` rows, so page by offset.
  async function listAll(
    bucket: string,
    prefix: string,
  ): Promise<{ data: { id: string | null; name: string }[] | null; error: unknown }> {
    const out: { id: string | null; name: string }[] = [];
    for (let offset = 0; ; offset += LIST_PAGE) {
      const { data, error } = await admin.storage
        .from(bucket)
        .list(prefix, { limit: LIST_PAGE, offset, sortBy: { column: "name", order: "asc" } });
      if (error) return { data: null, error };
      out.push(...(data ?? []));
      if (!data || data.length < LIST_PAGE) return { data: out, error: null };
    }
  }

  /** Every object path under <bucket>/<userId>/, one folder level deep (chat images). */
  async function objectsOf(bucket: string): Promise<string[] | null> {
    const { data, error } = await listAll(bucket, userId);
    if (error) return null;
    const paths: string[] = [];
    for (const entry of data ?? []) {
      // Folders come back without an id.
      if (entry.id) {
        paths.push(`${userId}/${entry.name}`);
        continue;
      }
      const inner = await listAll(bucket, `${userId}/${entry.name}`);
      if (inner.error) return null;
      for (const file of inner.data ?? []) paths.push(`${userId}/${entry.name}/${file.name}`);
    }
    return paths;
  }

  async function download(bucket: string, path: string): Promise<Blob | "missing" | null> {
    for (let attempt = 0; attempt < 3; attempt++) {
      const { data, error } = await admin.storage.from(bucket).download(path);
      if (data) return data;
      const status = storageStatus(error);
      if (status === 404 || status === 400) return "missing";
    }
    return null;
  }

  const avatarPaths = await objectsOf("avatars");
  if (!avatarPaths) return fail("avatar_list_failed");
  const chatPaths = await objectsOf("chat-images");
  if (!chatPaths) return fail("chat_images_list_failed");

  // 0. Evidence hold (migration 77).
  const { data: holdUntil, error: holdError } = await admin.rpc("legal_hold_for", {
    p_user: userId,
  });
  if (holdError) return fail("legal_hold_lookup_failed");
  let held = 0;
  if (holdUntil) {
    for (const [bucket, paths] of [
      ["avatars", avatarPaths],
      ["chat-images", chatPaths],
    ] as const) {
      for (const path of paths) {
        const original = await download(bucket, path);
        if (original === "missing") continue;
        if (!original) return fail("legal_hold_copy_failed");
        const { data: target, error: savedError } = await admin.rpc("legal_hold_saved", {
          p_user: userId,
          p_source_bucket: bucket,
          p_source_path: path,
          p_bytes: original.size,
        });
        if (savedError || typeof target !== "string") return fail("legal_hold_save_failed");
        const { error: copyError } = await admin.storage
          .from("legal-hold")
          .upload(target, original, {
            contentType: original.type || "image/jpeg",
            upsert: true,
          });
        if (copyError) return fail("legal_hold_copy_failed");
        held++;
      }
    }
  }

  // 1. Avatar files (photos and covers; the RPC cleared every URL).
  for (let i = 0; i < avatarPaths.length; i += 500) {
    const { error } = await admin.storage.from("avatars").remove(avatarPaths.slice(i, i + 500));
    if (error) return fail("avatar_remove_failed");
  }

  // 1b. Chat images (migration 58). Every reported photo's evidence copy still pending for this
  //     account is made first (migration 73), so the evidence outlives the original.
  const { data: pendingEvidence, error: evidenceListError } = await admin.rpc(
    "chat_image_evidence_list_for",
    { p_user: userId },
  );
  if (evidenceListError) return fail("chat_evidence_list_failed");
  for (const row of (pendingEvidence ?? []) as { report_id: string; path: string }[]) {
    if (!row.path.startsWith(`${userId}/`)) continue;
    const original = await download("chat-images", row.path);
    if (original === "missing") {
      const { error } = await admin.rpc("chat_image_evidence_saved", {
        p_report: row.report_id,
        p_path: null,
      });
      if (error) return fail("chat_evidence_save_failed");
      continue;
    }
    if (!original) return fail("chat_evidence_copy_failed");
    const target = `${row.report_id}.jpg`;
    const { error: copyError } = await admin.storage
      .from("chat-evidence")
      .upload(target, original, { contentType: "image/jpeg", upsert: true });
    if (copyError) return fail("chat_evidence_copy_failed");
    const { error: savedError } = await admin.rpc("chat_image_evidence_saved", {
      p_report: row.report_id,
      p_path: target,
    });
    if (savedError) return fail("chat_evidence_save_failed");
  }
  for (let i = 0; i < chatPaths.length; i += 500) {
    const { error } = await admin.storage.from("chat-images").remove(chatPaths.slice(i, i + 500));
    if (error) return fail("chat_images_remove_failed");
  }

  // 2. Provider tokens.
  // TODO(apple): when Sign in with Apple ships (Capacitor), POST the refresh token from
  // auth_provider_secrets to https://appleid.apple.com/auth/revoke and stamp
  // account_deletions.apple_token_revoked_at (App Review 5.1.1(v)). Until then the row goes.
  const { error: secretsError } = await admin
    .from("auth_provider_secrets")
    .delete()
    .eq("user_id", userId);
  if (secretsError) return fail("secrets_delete_failed");

  // 3. Processors. Resend, Sightengine and Supabase hold nothing per user beyond what is
  //    removed here; Stripe (migration 60) closes the connected account when its balance allows.
  const processorsNotified: Record<string, string> = {};
  const { data: stripeAccount, error: stripeLookupError } = await admin
    .from("coach_stripe_accounts")
    .select("stripe_account_id")
    .eq("coach_id", userId)
    .maybeSingle();
  if (stripeLookupError) return fail("stripe_lookup_failed");
  if (stripeAccount && deps.stripe) {
    const acct = stripeAccount.stripe_account_id as string;
    const { data: blocked, error: blockedError } = await admin.rpc("coach_stripe_close_blocked", {
      p_coach: userId,
    });
    if (blockedError) return fail("stripe_lookup_failed");
    const res =
      blocked === true
        ? null
        : await deps.stripe.request("DELETE", `/v1/accounts/${encodeURIComponent(acct)}`);
    if (res && (res.ok || res.status === 404)) {
      await admin.from("coach_stripe_accounts").delete().eq("coach_id", userId);
      processorsNotified.stripe = "account_deleted";
    } else {
      const { error: jobError } = await admin.from("stripe_jobs").upsert(
        {
          op: "close_account",
          stripe_account_id: acct,
          idempotency_key: `close:${acct}`,
          next_at: new Date(
            now().getTime() + (res ? 8 * 24 * 3600 * 1000 : 3600 * 1000),
          ).toISOString(),
        },
        { onConflict: "idempotency_key", ignoreDuplicates: true },
      );
      if (jobError) return fail("stripe_job_failed");
      processorsNotified.stripe = res
        ? `close_queued:${stripeErrorName(res)}`
        : "close_queued:refunds_pending";
    }
  } else if (stripeAccount) {
    processorsNotified.stripe = "no_key";
  }

  // 4. Auth user. A soft delete keeps an anonymous stub (the ban holds, the tombstone's foreign
  //    key stays) while freeing the email and identities. The message stays in the server log.
  const { error: deleteError } = await admin.auth.admin.deleteUser(userId, true);
  if (deleteError) {
    console.error(`delete-account: auth delete failed (${deleteError.name ?? "error"})`);
    return fail("auth_delete_failed");
  }

  // 5. Ledger.
  const { error: ledgerError } = await admin
    .from("account_deletions")
    .update({ completed_at: now().toISOString(), processors_notified: processorsNotified })
    .eq("user_id", userId);
  if (ledgerError) return fail("ledger_update_failed");

  return held > 0 ? { ok: true, held } : { ok: true };
}

/** Deletes expired legal-hold copies (migration 77). Returns how many were purged. */
export async function purgeLegalHolds(admin: SupabaseClient): Promise<number> {
  const { data, error } = await admin.rpc("legal_hold_purge_list", { p_limit: 200 });
  if (error) throw new Error("legal_hold_purge_list_failed");
  const rows = (data ?? []) as { id: string; path: string }[];
  if (rows.length === 0) return 0;
  const { error: removeError } = await admin.storage
    .from("legal-hold")
    .remove(rows.map((r) => r.path));
  if (removeError) throw new Error("legal_hold_remove_failed");
  const { data: n, error: purgedError } = await admin.rpc("legal_hold_purged", {
    p_ids: rows.map((r) => r.id),
  });
  if (purgedError) throw new Error("legal_hold_purged_failed");
  return typeof n === "number" ? n : rows.length;
}
