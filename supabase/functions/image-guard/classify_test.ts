// deno test --allow-read supabase/functions/image-guard
// The classifier step with mocked Sightengine answers (shapes from Sightengine's check.json
// documentation for nudity-2.1, weapon, offensive-2.0 and gore-2.0). No network.
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import { CLASSIFIER_MODELS, type ClassifyDeps, decide, readKeys, runClassify } from "./classify.ts";
import { parseGuardRequest } from "./guard.ts";

const uid = "6f1c1c1e-5b8e-4a3e-9d0a-3d1f2b4c5a6e";
const conv = "0b7c1a2e-3d4f-4a5b-8c6d-7e8f9a0b1c2d";
const path = `${uid}/${conv}/1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9.jpg`;
const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);

/** A Sightengine success answer with every score low; override parts per test. */
function answer(over: {
  nudity?: Record<string, number>;
  gore?: number;
  offensive?: Record<string, number>;
  weapon?: Record<string, number>;
  operations?: number;
}) {
  return {
    status: "success",
    request: { id: "req_test", timestamp: 1, operations: over.operations ?? 4 },
    nudity: {
      sexual_activity: 0.001,
      sexual_display: 0.001,
      erotica: 0.001,
      very_suggestive: 0.002,
      suggestive: 0.01,
      mildly_suggestive: 0.01,
      suggestive_classes: { bikini: 0.001, lingerie: 0.001 },
      none: 0.99,
      context: { indoor_other: 0.8 },
      ...over.nudity,
    },
    weapon: {
      classes: {
        firearm: 0.001,
        firearm_gesture: 0.001,
        firearm_toy: 0.001,
        knife: 0.001,
        ...over.weapon,
      },
      firearm_action: { aiming_threat: 0.001 },
    },
    offensive: {
      nazi: 0.001,
      asian_swastika: 0.001,
      confederate: 0.001,
      supremacist: 0.001,
      terrorist: 0.001,
      middle_finger: 0.001,
      ...over.offensive,
    },
    gore: { prob: over.gore ?? 0.001, classes: { very_bloody: 0.001 }, type: { real: 0.01 } },
    media: { id: "med_test", uri: "image.jpg" },
  };
}

interface Fake extends ClassifyDeps {
  calls: { name: string; args: Record<string, unknown> }[];
  sent: FormData[];
}

function fake(opts: {
  keys?: boolean;
  pending?: boolean;
  allowed?: boolean;
  bytes?: Uint8Array | null | "too_large";
  reply?: { status: number; body: unknown } | "throw";
}): Fake {
  const f: Fake = {
    calls: [],
    sent: [],
    keys: opts.keys === false ? null : { user: "u", secret: "s" },
    rpc(name, args) {
      f.calls.push({ name, args });
      if (name === "chat_classifier_reserve") {
        return Promise.resolve({
          pending: opts.pending ?? true,
          allowed: opts.allowed ?? true,
          used: 4,
          cap: 1800,
        });
      }
      if (name === "chat_image_classified") return Promise.resolve(1);
      if (name === "chat_classifier_settle") return Promise.resolve(0);
      return Promise.reject(new Error(`unexpected ${name}`));
    },
    download: () => Promise.resolve(opts.bytes === undefined ? jpeg : opts.bytes),
    sightengine(form) {
      f.sent.push(form);
      if (opts.reply === "throw") return Promise.reject(new Error("network"));
      return Promise.resolve(opts.reply ?? { status: 200, body: answer({}) });
    },
  };
  return f;
}

const verdictCall = (f: Fake) => f.calls.find((c) => c.name === "chat_image_classified")?.args;

Deno.test("parseGuardRequest: classify is for chat images only", () => {
  assertEquals(parseGuardRequest({ op: "classify", bucket: "chat-images", path }), {
    op: "classify",
    bucket: "chat-images",
    path,
  });
  assertEquals(
    parseGuardRequest({ op: "classify", bucket: "avatars", path: `${uid}/1.jpg` }),
    null,
  );
  assertEquals(
    parseGuardRequest({ op: "classify", bucket: "chat-images", path: "../x.jpg" }),
    null,
  );
});

Deno.test("readKeys: both secrets or nothing", () => {
  const env = (m: Record<string, string>) => (n: string) => m[n];
  assertEquals(readKeys(env({})), null);
  assertEquals(readKeys(env({ SIGHTENGINE_API_USER: "u" })), null);
  assertEquals(readKeys(env({ SIGHTENGINE_API_USER: "u", SIGHTENGINE_API_SECRET: "  " })), null);
  assertEquals(readKeys(env({ SIGHTENGINE_API_USER: "u", SIGHTENGINE_API_SECRET: "s" })), {
    user: "u",
    secret: "s",
  });
});

Deno.test("decide: a clean photo is visible", () => {
  const d = decide(answer({}));
  assertEquals(d?.verdict, "visible");
  assertEquals(d?.category, null);
});

Deno.test("decide: high sexual, gore or hate scores are blocked", () => {
  assertEquals(decide(answer({ nudity: { sexual_activity: 0.93 } }))?.verdict, "blocked");
  assertEquals(decide(answer({ nudity: { erotica: 0.85 } }))?.category, "sexual_content");
  assertEquals(decide(answer({ gore: 0.9 }))?.category, "violence");
  const hate = decide(answer({ offensive: { nazi: 0.97 } }));
  assertEquals(hate?.verdict, "blocked");
  assertEquals(hate?.category, "hate");
  // The highest high score names the category.
  assertEquals(
    decide(answer({ gore: 0.88, nudity: { sexual_display: 0.95 } }))?.category,
    "sexual_content",
  );
});

Deno.test("decide: medium scores are queued for a moderator", () => {
  const s = decide(answer({ nudity: { sexual_display: 0.6 } }));
  assertEquals(s?.verdict, "queued");
  assertEquals(s?.category, "sexual_content");
  assertEquals(decide(answer({ gore: 0.5 }))?.category, "violence");
  assertEquals(decide(answer({ offensive: { confederate: 0.95 } }))?.verdict, "queued");
  assertEquals(decide(answer({ offensive: { supremacist: 0.7 } }))?.category, "hate");
});

Deno.test("decide: weapons are queued at high confidence, never blocked", () => {
  assertEquals(decide(answer({ weapon: { firearm: 0.7 } }))?.verdict, "visible");
  const w = decide(answer({ weapon: { knife: 0.96 } }));
  assertEquals(w?.verdict, "queued");
  assertEquals(w?.category, "violence");
  assertEquals(
    decide(answer({ weapon: { firearm_toy: 0.99, firearm_gesture: 0.99 } }))?.verdict,
    "visible",
  );
});

Deno.test("decide: suggestive classes, the middle finger and religious swastikas pass", () => {
  const d = decide(
    answer({
      nudity: { suggestive: 0.9, very_suggestive: 0.8 },
      offensive: { middle_finger: 0.99, asian_swastika: 0.95 },
    }),
  );
  assertEquals(d?.verdict, "visible");
});

Deno.test("decide: a failure or a missing model is no verdict", () => {
  assertEquals(decide({ status: "failure", error: { type: "usage_limit", code: 32 } }), null);
  assertEquals(decide(null), null);
  const partial = answer({}) as Record<string, unknown>;
  delete partial.gore;
  assertEquals(decide(partial), null);
});

Deno.test("classify: no key fails closed (blocked) and calls nothing else", async () => {
  const f = fake({ keys: false });
  const r = await runClassify(f, { bucket: "chat-images", path });
  assertEquals(r, { skipped: "no_key", verdict: "blocked", messages: 1 });
  assertEquals(f.sent.length, 0);
  assertEquals(
    f.calls.map((c) => c.name),
    ["chat_image_classified"],
  );
  assertEquals(verdictCall(f)?.p_verdict, "blocked");
  assertEquals((verdictCall(f)?.p_scores as Record<string, unknown>).reason, "no_classifier");
});

Deno.test("classify: nothing waiting means no call and no operations", async () => {
  const f = fake({ pending: false });
  assertEquals(await runClassify(f, { bucket: "chat-images", path }), { skipped: "not_pending" });
  assertEquals(f.sent.length, 0);
  assertEquals(verdictCall(f), undefined);
});

Deno.test("classify: past the monthly cap the image waits for a moderator", async () => {
  const f = fake({ allowed: false });
  const r = await runClassify(f, { bucket: "chat-images", path });
  assert("verdict" in r);
  assertEquals(r.verdict, "queued");
  assertEquals("reason" in r && r.reason, "cap");
  assertEquals(f.sent.length, 0);
  assertEquals(verdictCall(f)?.p_verdict, "queued");
});

Deno.test("classify: a clean photo is visible; the form carries the four models", async () => {
  const f = fake({});
  const r = await runClassify(f, { bucket: "chat-images", path });
  assertEquals(r, {
    verdict: "visible",
    reason: "classified",
    category: null,
    operations: 4,
    messages: 1,
  });
  assertEquals(f.sent.length, 1);
  const form = f.sent[0]!;
  assertEquals(form.get("models"), CLASSIFIER_MODELS.join(","));
  assertEquals(form.get("api_user"), "u");
  assert(form.get("media") instanceof Blob);
  const reserve = f.calls.find((c) => c.name === "chat_classifier_reserve")!;
  assertEquals(reserve.args, { p_path: path, p_operations: 4 });
  // Sightengine counted what was reserved: nothing to settle.
  assertEquals(
    f.calls.some((c) => c.name === "chat_classifier_settle"),
    false,
  );
  const scores = verdictCall(f)?.p_scores as Record<string, unknown>;
  assertEquals(Object.keys(scores).sort(), [
    "category",
    "gore",
    "hate",
    "reason",
    "sexual",
    "weapon",
  ]);
});

Deno.test("classify: a high score blocks; a medium one queues", async () => {
  const b = fake({ reply: { status: 200, body: answer({ nudity: { sexual_activity: 0.99 } }) } });
  const rb = await runClassify(b, { bucket: "chat-images", path });
  assertEquals("verdict" in rb && rb.verdict, "blocked");
  assertEquals(verdictCall(b)?.p_verdict, "blocked");
  const q = fake({ reply: { status: 200, body: answer({ gore: 0.6 }) } });
  await runClassify(q, { bucket: "chat-images", path });
  assertEquals(verdictCall(q)?.p_verdict, "queued");
  assertEquals((verdictCall(q)?.p_scores as Record<string, unknown>).category, "violence");
});

Deno.test(
  "classify: Sightengine errors queue the image and refund what it did not count",
  async () => {
    for (const reply of [
      "throw" as const,
      {
        status: 200,
        body: {
          status: "failure",
          request: { operations: 0 },
          error: { type: "usage_limit", code: 32 },
        },
      },
      { status: 500, body: null },
      { status: 200, body: "not json" },
    ]) {
      const f = fake({ reply });
      const r = await runClassify(f, { bucket: "chat-images", path });
      assertEquals("reason" in r && r.reason, "classifier_error", JSON.stringify(reply));
      assertEquals(verdictCall(f)?.p_verdict, "queued");
      const settle = f.calls.find((c) => c.name === "chat_classifier_settle");
      assertEquals(settle?.args, { p_reserved: 4, p_used: 0 });
    }
  },
);

Deno.test("classify: a different operation count is settled", async () => {
  const f = fake({ reply: { status: 200, body: answer({ operations: 3 }) } });
  await runClassify(f, { bucket: "chat-images", path });
  assertEquals(f.calls.find((c) => c.name === "chat_classifier_settle")?.args, {
    p_reserved: 4,
    p_used: 3,
  });
});

Deno.test("classify: a missing or oversized object is blocked without a call", async () => {
  for (const bytes of [null, "too_large" as const]) {
    const f = fake({ bytes });
    const r = await runClassify(f, { bucket: "chat-images", path });
    assertEquals("verdict" in r && r.verdict, "blocked");
    assertEquals(f.sent.length, 0);
    assertEquals(f.calls.find((c) => c.name === "chat_classifier_settle")?.args, {
      p_reserved: 4,
      p_used: 0,
    });
  }
});
