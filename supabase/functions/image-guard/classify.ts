// image-guard: the chat-image classifier step (migration 71; design: MESSAGING_DESIGN.md section
// 10, TRUST-SAFETY-LEGAL section 7). Fake I/O in classify_test.ts.
//
//   classify  for one chat-images object whose message waits for a verdict (pending or
//             classifying, its pHash check passed): reserve the operations under the monthly
//             cap (chat_classifier_reserve), download the object with the service role, send it
//             to Sightengine's check.json (models nudity-2.1, weapon, offensive-2.0, gore-2.0)
//             and record the verdict through chat_image_classified: visible, queued (hidden, an
//             automatic report for a moderator) or blocked (never shown, the object deleted).
//
// Fails closed. Without SIGHTENGINE_API_USER and SIGHTENGINE_API_SECRET the answer is
// {skipped: "no_key"} and the image is blocked (chat images stay off until the keys exist and
// meta.chat_images is turned on, so this only happens when the flag was turned on too early).
// Past the monthly cap, on a Sightengine error or on an answer this file cannot read, the image
// is queued for a moderator. Only the verdict and a few rounded scores are stored; the image is
// never logged, kept or returned.

/** Sightengine models, one operation each (Sightengine bills per model per image). */
export const CLASSIFIER_MODELS = ["nudity-2.1", "weapon", "offensive-2.0", "gore-2.0"] as const;
export const SIGHTENGINE_URL = "https://api.sightengine.com/1.0/check.json";

/** At or above: blocked without a moderator. */
export const HIGH = 0.85;
/** At or above (and below HIGH): hidden and queued for a moderator. */
export const MEDIUM = 0.5;

export type Verdict = "visible" | "queued" | "blocked";
export type Category = "sexual_content" | "violence" | "hate" | "other";

export interface Scores {
  sexual: number;
  gore: number;
  hate: number;
  weapon: number;
}

export interface Decision {
  verdict: Verdict;
  category: Category | null;
  scores: Scores;
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : null;
}

function obj(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}

function maxOf(o: Record<string, unknown> | null, keys: string[]): number | null {
  if (!o) return null;
  let best: number | null = null;
  for (const k of keys) {
    const n = num(o[k]);
    if (n !== null) best = best === null ? n : Math.max(best, n);
  }
  return best;
}

const round = (n: number) => Math.round(n * 1000) / 1000;

/**
 * The verdict for one successful check.json answer, or null when the answer lacks a model's
 * scores (the caller then queues the image: an unreadable answer is never a pass).
 *
 *   sexual  nudity.sexual_activity, sexual_display, erotica   block >= HIGH, queue >= MEDIUM
 *   gore    gore.prob                                         block >= HIGH, queue >= MEDIUM
 *   hate    offensive.nazi, supremacist, terrorist            block >= HIGH, queue >= MEDIUM
 *           offensive.confederate                             queue >= MEDIUM
 *   weapon  weapon.classes.firearm, knife                     queue >= HIGH, never blocked
 *
 * A firearm or a knife in a photo is not against the rules by itself (a range day, a cooking
 * class), so weapons go to a moderator rather than being blocked. Toy guns, finger guns, the
 * middle finger and religious swastikas are not scored. Suggestive classes (swimwear, lingerie)
 * pass.
 */
export function decide(answer: unknown): Decision | null {
  const a = obj(answer);
  if (!a || a.status !== "success") return null;
  const nudity = obj(a.nudity);
  const gore = obj(a.gore);
  const offensive = obj(a.offensive);
  const weapon = obj(a.weapon);
  const sexual = maxOf(nudity, ["sexual_activity", "sexual_display", "erotica"]);
  const goreProb = num(gore?.prob);
  const hateHigh = maxOf(offensive, ["nazi", "supremacist", "terrorist"]);
  const hateLow = maxOf(offensive, ["confederate"]);
  const weaponProb = maxOf(obj(weapon?.classes), ["firearm", "knife"]);
  if (sexual === null || goreProb === null || hateHigh === null || weaponProb === null) {
    return null;
  }
  const hate = Math.max(hateHigh, hateLow ?? 0);
  const scores: Scores = {
    sexual: round(sexual),
    gore: round(goreProb),
    hate: round(hate),
    weapon: round(weaponProb),
  };

  const blockers: [number, Category][] = [
    [sexual, "sexual_content"],
    [goreProb, "violence"],
    [hateHigh, "hate"],
  ];
  const high = blockers.filter(([s]) => s >= HIGH).sort((x, y) => y[0] - x[0])[0];
  if (high) return { verdict: "blocked", category: high[1], scores };

  const queuers: [number, Category][] = [
    [sexual, "sexual_content"],
    [goreProb, "violence"],
    [hate, "hate"],
    [weaponProb >= HIGH ? weaponProb : 0, "violence"],
  ];
  const medium = queuers.filter(([s]) => s >= MEDIUM).sort((x, y) => y[0] - x[0])[0];
  if (medium) return { verdict: "queued", category: medium[1], scores };
  return { verdict: "visible", category: null, scores };
}

export interface SightengineKeys {
  user: string;
  secret: string;
}

/** Both secrets, or null when either is missing or blank. */
export function readKeys(get: (name: string) => string | undefined): SightengineKeys | null {
  const user = get("SIGHTENGINE_API_USER")?.trim();
  const secret = get("SIGHTENGINE_API_SECRET")?.trim();
  return user && secret ? { user, secret } : null;
}

export interface ClassifyDeps {
  rpc(name: string, args: Record<string, unknown>): Promise<unknown>;
  /** The object's bytes, null when it does not exist, "too_large" over MAX_BYTES. */
  download(bucket: string, path: string): Promise<Uint8Array | null | "too_large">;
  /** POSTs the form to Sightengine and returns the parsed JSON body (throws on network errors). */
  sightengine(form: FormData): Promise<{ status: number; body: unknown }>;
  keys: SightengineKeys | null;
}

export type ClassifyResult =
  | { skipped: "no_key"; verdict: "blocked"; messages: number }
  | { skipped: "not_pending" }
  | {
      verdict: Verdict;
      reason: "classified" | "cap" | "classifier_error" | "missing" | "too_large";
      category: Category | null;
      operations: number;
      messages: number;
    };

async function record(
  deps: ClassifyDeps,
  path: string,
  verdict: Verdict,
  scores: Record<string, unknown>,
): Promise<number> {
  const n = await deps.rpc("chat_image_classified", {
    p_bucket: "chat-images",
    p_path: path,
    p_verdict: verdict,
    p_scores: scores,
  });
  return Number(n ?? 0);
}

/** Classifies one chat image. The caller sweeps afterwards when the verdict is blocked. */
export async function runClassify(
  deps: ClassifyDeps,
  req: { bucket: string; path: string },
): Promise<ClassifyResult> {
  const path = req.path;
  if (!deps.keys) {
    // Fail closed: no classifier, no image.
    const messages = await record(deps, path, "blocked", { reason: "no_classifier" });
    return { skipped: "no_key", verdict: "blocked", messages };
  }

  const reserved = CLASSIFIER_MODELS.length;
  const slot = (await deps.rpc("chat_classifier_reserve", {
    p_path: path,
    p_operations: reserved,
  })) as { pending?: boolean; allowed?: boolean } | null;
  if (!slot?.pending) return { skipped: "not_pending" };
  if (!slot.allowed) {
    const messages = await record(deps, path, "queued", { reason: "cap", category: "other" });
    return { verdict: "queued", reason: "cap", category: "other", operations: 0, messages };
  }

  let used = 0;
  try {
    const bytes = await deps.download(req.bucket, path);
    if (bytes === null || bytes === "too_large") {
      const reason = bytes === null ? "missing" : "too_large";
      const messages = await record(deps, path, "blocked", { reason });
      return { verdict: "blocked", reason, category: null, operations: 0, messages };
    }

    const form = new FormData();
    form.append("media", new Blob([bytes], { type: "image/jpeg" }), "image.jpg");
    form.append("models", CLASSIFIER_MODELS.join(","));
    form.append("api_user", deps.keys.user);
    form.append("api_secret", deps.keys.secret);

    let answer: { status: number; body: unknown } | null = null;
    try {
      answer = await deps.sightengine(form);
    } catch {
      answer = null;
    }
    const body = obj(answer?.body);
    const rawOps = obj(body?.request)?.operations;
    const ops =
      typeof rawOps === "number" && Number.isFinite(rawOps) && rawOps >= 0 ? rawOps : null;
    const decision = answer && answer.status === 200 ? decide(body) : null;
    // What Sightengine counted; an answer without the count is taken as the full reservation
    // when it carried results and as nothing when it failed (a refused call costs nothing).
    used = Math.max(0, Math.round(ops ?? (decision ? reserved : 0)));

    if (!decision) {
      const messages = await record(deps, path, "queued", {
        reason: "classifier_error",
        category: "other",
      });
      return {
        verdict: "queued",
        reason: "classifier_error",
        category: "other",
        operations: used,
        messages,
      };
    }
    const messages = await record(deps, path, decision.verdict, {
      reason: "classified",
      category: decision.category,
      ...decision.scores,
    });
    return {
      verdict: decision.verdict,
      reason: "classified",
      category: decision.category,
      operations: used,
      messages,
    };
  } finally {
    if (used !== reserved) {
      await deps.rpc("chat_classifier_settle", { p_reserved: reserved, p_used: used });
    }
  }
}
