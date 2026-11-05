// image-guard: perceptual hashing for the NCII removal flow (migration 52; the logic is in
// guard.ts, hash.ts and decode.ts).
//
//   POST /image-guard {op: "check", bucket, path} -> hashes one Storage object and records it
//                                                     (image_guard_record); deletes it when it
//                                                     matches a removed image.
//   POST /image-guard {op: "sweep"}               -> deletes the objects waiting for deletion.
//
// The caller is the database (the image reference triggers, mod_takedown_block_image and the
// pg_cron job image-guard-tick, all through pg_net and public.image_guard_dispatch), not a user,
// so the gateway JWT check is off (config.toml). Every request must carry the header
// x-image-guard-secret, checked through image_guard_verify_secret (vault secret
// image_guard_secret, generated inside the database by migration 52; it never leaves the
// database except in that pg_net header). Free, server-side, no paid API: the hashes are
// computed here in plain TypeScript. Only hashes are stored; the bytes are never logged or kept.
// Responses carry the outcome and counts only. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are
// injected by Supabase.
import { type GuardDeps, MAX_BYTES, parseGuardRequest, runCheck, runSweep } from "./guard.ts";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

class RpcFailure extends Error {
  constructor(
    readonly status: number,
    readonly body: string,
  ) {
    super(`rpc_http_${status}`);
  }
}

function objectUrl(base: string, bucket: string, path: string): string {
  return `${base}/storage/v1/object/${bucket}/${path.split("/").map(encodeURIComponent).join("/")}`;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "not_found" }, 404);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ error: "misconfigured" }, 500);
  const auth = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` };

  const rpc = async (name: string, args: Record<string, unknown>) => {
    const res = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify(args),
    });
    const text = await res.text();
    if (!res.ok) throw new RpcFailure(res.status, text);
    return text ? JSON.parse(text) : null;
  };

  const secret = req.headers.get("x-image-guard-secret") ?? "";
  let allowed = false;
  try {
    allowed =
      secret.length >= 32 &&
      (await rpc("image_guard_verify_secret", { p_secret: secret })) === true;
  } catch (err) {
    console.error(
      "image-guard: secret check failed",
      err instanceof RpcFailure ? err.status : String(err),
    );
    return json({ error: "secret_check_failed" }, 500);
  }
  if (!allowed) {
    await req.body?.cancel();
    return json({ error: "unauthorized" }, 401);
  }

  let parsed;
  try {
    parsed = parseGuardRequest(await req.json());
  } catch {
    parsed = null;
  }
  if (!parsed) return json({ error: "bad_request" }, 400);

  const deps: GuardDeps = {
    rpc,
    download: async (bucket, path) => {
      const res = await fetch(objectUrl(supabaseUrl, bucket, path), { headers: auth });
      if (res.status === 404 || res.status === 400) {
        await res.body?.cancel();
        return null;
      }
      if (!res.ok) {
        await res.body?.cancel();
        throw new Error(`storage_http_${res.status}`);
      }
      const length = Number(res.headers.get("content-length") ?? "0");
      if (length > MAX_BYTES) {
        await res.body?.cancel();
        return "too_large";
      }
      const bytes = new Uint8Array(await res.arrayBuffer());
      return bytes.length > MAX_BYTES ? "too_large" : bytes;
    },
    remove: async (bucket, paths) => {
      const res = await fetch(`${supabaseUrl}/storage/v1/object/${bucket}`, {
        method: "DELETE",
        headers: { ...auth, "Content-Type": "application/json" },
        body: JSON.stringify({ prefixes: paths }),
      });
      await res.body?.cancel();
      if (!res.ok) throw new Error(`storage_delete_http_${res.status}`);
    },
  };

  try {
    if (parsed.op === "sweep") {
      const deleted = await runSweep(deps);
      console.log("image-guard sweep", JSON.stringify({ deleted }));
      return json({ deleted });
    }
    const result = await runCheck(deps, parsed);
    console.log("image-guard check", JSON.stringify(result));
    return json(result);
  } catch (err) {
    if (err instanceof RpcFailure) {
      console.error("image-guard: rpc failed", err.status, err.body.slice(0, 300));
      return json({ error: "rpc_failed" }, 502);
    }
    console.error("image-guard: failed", String(err).slice(0, 200));
    return json({ error: "guard_failed" }, 500);
  }
});
