import { assertEquals } from "jsr:@std/assert@1.0.19";
import { idempotencyKey, RESEND_EMAILS_URL, sendResendEmails } from "./resend.ts";
import type { EmailMessage } from "./worker.ts";

function msg(id: string): EmailMessage {
  return { id, to: `${id}@example.com`, subject: "s", text: "t", html: "<p>t</p>", headers: {} };
}

const noSleep = () => Promise.resolve();

function fakeFetch(statuses: Record<string, number | "throw">, names: Record<string, string> = {}) {
  const seen: { url: string; key: string | null; to: string }[] = [];
  const impl = ((url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body)) as { to: string[] };
    const to = body.to[0];
    const id = to.split("@")[0];
    seen.push({ url, key: new Headers(init.headers).get("Idempotency-Key"), to });
    const st = statuses[id] ?? 200;
    if (st === "throw") return Promise.reject(new Error("network"));
    return Promise.resolve(
      new Response(JSON.stringify(names[id] ? { name: names[id] } : { id: `re-${id}` }), {
        status: st,
      }),
    );
  }) as unknown as typeof fetch;
  return { impl, seen };
}

Deno.test("one request per email, keyed by the notification id", async () => {
  const { impl, seen } = fakeFetch({});
  const out = await sendResendEmails("k", [msg("a"), msg("b")], impl, undefined, noSleep);
  assertEquals(out, ["sent", "sent"]);
  assertEquals(
    seen.map((s) => [s.url, s.key]),
    [
      [RESEND_EMAILS_URL, idempotencyKey("a")],
      [RESEND_EMAILS_URL, idempotencyKey("b")],
    ],
  );
});

Deno.test("a bad address fails only its own email", async () => {
  const { impl } = fakeFetch({ b: 422 }, { b: "validation_error" });
  const out = await sendResendEmails("k", [msg("a"), msg("b"), msg("c")], impl, undefined, noSleep);
  assertEquals(out, ["sent", "failed", "sent"]);
});

Deno.test("5xx and network errors retry; a reused key counts as sent", async () => {
  const { impl } = fakeFetch(
    { a: 503, b: "throw", c: 409, d: 409 },
    { c: "invalid_idempotent_request", d: "concurrent_idempotent_requests" },
  );
  const out = await sendResendEmails(
    "k",
    [msg("a"), msg("b"), msg("c"), msg("d")],
    impl,
    undefined,
    noSleep,
  );
  assertEquals(out, ["retry", "retry", "sent", "retry"]);
});

Deno.test("429 or a refused key stops the run and retries the rest", async () => {
  for (const st of [429, 401]) {
    const { impl, seen } = fakeFetch({ b: st });
    const out = await sendResendEmails(
      "k",
      [msg("a"), msg("b"), msg("c")],
      impl,
      undefined,
      noSleep,
    );
    assertEquals(out, ["sent", "retry", "retry"]);
    assertEquals(seen.length, 2);
  }
});
