// recs-embed tests (fake model, clock and RPCs; no network, no model download).
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import {
  type ClaimedRow,
  createHandler,
  errorCode,
  type Model,
  runBatch,
  toVector,
} from "./embed.ts";

const SECRET = "s".repeat(64);

function unit(i: number): number[] {
  const v = new Array(384).fill(0);
  v[i % 384] = 1;
  return v;
}

function rows(n: number): ClaimedRow[] {
  return Array.from({ length: n }, (_, i) => ({
    subject_kind: i % 2 ? "event" : "hub",
    subject_id: `id-${i}`,
    content_hash: `hash-${i}`,
    text: `Private text number ${i} with someone@example.com`,
  }));
}

function fakeModel(over: (text: string, i: number) => unknown = (_t, i) => unit(i)): {
  model: Model;
  calls: { text: string; options: unknown }[];
} {
  const calls: { text: string; options: unknown }[] = [];
  return {
    calls,
    model: {
      run(text, options) {
        calls.push({ text, options });
        try {
          return Promise.resolve(over(text, calls.length - 1));
        } catch (e) {
          return Promise.reject(e);
        }
      },
    },
  };
}

Deno.test(
  "runBatch embeds every claimed row with mean_pool and normalize, then records once",
  async () => {
    const { model, calls } = fakeModel();
    const recorded: unknown[][] = [];
    const res = await runBatch({
      model,
      now: () => 0,
      claim: (limit) => {
        assertEquals(limit, 24);
        return Promise.resolve(rows(3));
      },
      record: (r) => {
        recorded.push(r);
        return Promise.resolve(r.length);
      },
      fail: () => Promise.reject(new Error("unexpected")),
    });
    assertEquals(res, { claimed: 3, embedded: 3, recorded: 3, failed: 0, left: 0, errors: {} });
    assertEquals(calls.length, 3);
    assertEquals(calls[0].options, { mean_pool: true, normalize: true });
    assertEquals(recorded.length, 1);
    const first = recorded[0][0] as { kind: string; id: string; hash: string; embedding: number[] };
    assertEquals(
      [first.kind, first.id, first.hash, first.embedding.length],
      ["hub", "id-0", "hash-0", 384],
    );
  },
);

Deno.test("runBatch stops at the wall-clock budget and leaves the rest leased", async () => {
  let t = 0;
  const { model, calls } = fakeModel((_text, i) => {
    t += 20_000; // each inference takes 20 s
    return unit(i);
  });
  const res = await runBatch(
    {
      model,
      now: () => t,
      claim: () => Promise.resolve(rows(5)),
      record: (r) => Promise.resolve(r.length),
      fail: () => Promise.resolve(),
    },
    { budgetMs: 50_000 },
  );
  // 0 s, 20 s and 40 s start; at 60 s the budget is spent.
  assertEquals(calls.length, 3);
  assertEquals(res.embedded, 3);
  assertEquals(res.left, 2);
});

Deno.test("a model error marks only that row failed; the rest record", async () => {
  const { model } = fakeModel((_t, i) => {
    if (i === 1) throw new Error("Out of memory while running text: secret words");
    return unit(i);
  });
  const failed: { id: string; code: string }[] = [];
  let recorded: string[] = [];
  const res = await runBatch({
    model,
    now: () => 0,
    claim: () => Promise.resolve(rows(3)),
    record: (r) => {
      recorded = r.map((x) => x.id);
      return Promise.resolve(r.length);
    },
    fail: (row, code) => {
      failed.push({ id: row.subject_id, code });
      return Promise.resolve();
    },
  });
  assertEquals(failed, [{ id: "id-1", code: "model_error" }]);
  assertEquals(recorded, ["id-0", "id-2"]);
  assertEquals(res.failed, 1);
  assertEquals(res.errors, { model_error: 1 });
});

Deno.test("a wrong length is rejected (bad_dimensions) and never recorded", async () => {
  const { model } = fakeModel((_t, i) => (i === 0 ? new Array(383).fill(0.05) : unit(i)));
  const failed: string[] = [];
  let recorded = 0;
  await runBatch({
    model,
    now: () => 0,
    claim: () => Promise.resolve(rows(2)),
    record: (r) => {
      recorded = r.length;
      return Promise.resolve(r.length);
    },
    fail: (_row, code) => {
      failed.push(code);
      return Promise.resolve();
    },
  });
  assertEquals(failed, ["bad_dimensions"]);
  assertEquals(recorded, 1);
});

Deno.test("toVector accepts typed arrays and refuses non-finite values", () => {
  assertEquals(toVector(new Float32Array(384)).length, 384);
  let code = "";
  try {
    toVector([...new Array(383).fill(0), Number.NaN]);
  } catch (e) {
    code = errorCode(e);
  }
  assertEquals(code, "not_finite");
  assertEquals(errorCode(new Error("Some Message: with text")), "model_error");
  assertEquals(
    errorCode(new Error("rpc_recs_embed_record_http_500")),
    "rpc_recs_embed_record_http_500",
  );
});

Deno.test("nothing claimed: no model call, no record call", async () => {
  const { model, calls } = fakeModel();
  let recordCalls = 0;
  const res = await runBatch({
    model,
    now: () => 0,
    claim: () => Promise.resolve([]),
    record: () => {
      recordCalls++;
      return Promise.resolve(0);
    },
    fail: () => Promise.resolve(),
  });
  assertEquals([calls.length, recordCalls, res.claimed], [0, 0, 0]);
});

function handler(over: { verify?: boolean; claimed?: ClaimedRow[]; logs?: string[] } = {}) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const { model } = fakeModel();
  const h = createHandler({
    rpc: (name, args) => {
      calls.push({ name, args });
      if (name === "recs_embed_verify_secret")
        return Promise.resolve(over.verify ?? args.p_secret === SECRET);
      if (name === "recs_embed_claim") return Promise.resolve(over.claimed ?? rows(2));
      if (name === "recs_embed_record") return Promise.resolve((args.p_rows as unknown[]).length);
      return Promise.resolve(null);
    },
    model: () => model,
    now: () => 0,
    log: (line) => over.logs?.push(line),
  });
  return { h, calls };
}

Deno.test(
  "the secret gate: 401 without or with a wrong x-recs-secret, and nothing is claimed",
  async () => {
    const variants: Record<string, string>[] = [
      {},
      { "x-recs-secret": "short" },
      { "x-recs-secret": "w".repeat(64) },
    ];
    for (const headers of variants) {
      const { h, calls } = handler();
      const res = await h(
        new Request("http://x/recs-embed", { method: "POST", headers, body: "{}" }),
      );
      assertEquals(res.status, 401);
      await res.body?.cancel();
      assert(!calls.some((c) => c.name === "recs_embed_claim"));
    }
    const { h } = handler();
    const get = await h(new Request("http://x/recs-embed"));
    assertEquals(get.status, 404);
    await get.body?.cancel();
  },
);

Deno.test("with the secret: one batch, counts only in the answer and in the log", async () => {
  const logs: string[] = [];
  const { h, calls } = handler({ logs });
  const res = await h(
    new Request("http://x/recs-embed", {
      method: "POST",
      headers: { "x-recs-secret": SECRET },
      body: "{}",
    }),
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body, { claimed: 2, embedded: 2, recorded: 2, failed: 0, left: 0, errors: {} });
  assertEquals(
    calls.map((c) => c.name),
    ["recs_embed_verify_secret", "recs_embed_claim", "recs_embed_record"],
  );
  assertEquals(calls[1].args, { p_limit: 24 });
  assert(logs.length >= 1);
  for (const line of logs) {
    assert(!line.includes("Private text"), "a text was logged");
    assert(!line.includes("@example.com"), "an address was logged");
    assert(!line.includes(SECRET), "the secret was logged");
  }
});

Deno.test("a failing secret check answers 500 without claiming", async () => {
  const calls: string[] = [];
  const h = createHandler({
    rpc: (name) => {
      calls.push(name);
      return Promise.reject(new Error("rpc_recs_embed_verify_secret_http_503"));
    },
    model: () => fakeModel().model,
  });
  const res = await h(
    new Request("http://x/recs-embed", { method: "POST", headers: { "x-recs-secret": SECRET } }),
  );
  assertEquals(res.status, 500);
  await res.body?.cancel();
  assertEquals(calls, ["recs_embed_verify_secret"]);
});
