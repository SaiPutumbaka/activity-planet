// deno test supabase/functions/organizer-verify (stubbed DoH, no network)
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { checkDns, dohUrl, handleVerify, txtValues } from "./verify.ts";

const TOKEN = "ap-verify-abcdefghijklmnopqrstuvwx";
const NAME = "_activityplanet.example.org";
const CLAIM = "0b9e7c1a-1111-4222-8333-944445555666";

function doh(body: unknown, status = 200) {
  const seen: string[] = [];
  const f = (url: string, init: RequestInit) => {
    seen.push(url);
    assertEquals((init.headers as Record<string, string>).accept, "application/dns-json");
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  };
  return { f, seen };
}

Deno.test("the DoH request names only the record and type", () => {
  assertEquals(
    dohUrl(NAME),
    "https://cloudflare-dns.com/dns-query?name=_activityplanet.example.org&type=TXT",
  );
});

Deno.test("a quoted and split TXT record is joined", () => {
  const half = TOKEN.slice(0, 15);
  assertEquals(txtValues({ Answer: [{ type: 16, data: `"${half}" "${TOKEN.slice(15)}"` }] }), [
    TOKEN,
  ]);
  assertEquals(txtValues({ Answer: [{ type: 5, data: "cname.example." }] }), []);
});

Deno.test("verified, wrong token, NXDOMAIN, no TXT, resolver error", async () => {
  const ok = doh({
    Status: 0,
    Answer: [
      { type: 16, data: `"v=spf1 -all"` },
      { type: 16, data: `"${TOKEN}"` },
    ],
  });
  assertEquals(await checkDns(NAME, TOKEN, ok.f), { kind: "verified" });
  assertEquals(ok.seen.length, 1);
  assertEquals(
    await checkDns(
      NAME,
      TOKEN,
      doh({ Status: 0, Answer: [{ type: 16, data: `"ap-verify-zzzzzzzzzzzzzzzzzzzzzzzz"` }] }).f,
    ),
    {
      kind: "dns_no_txt",
      reason: "wrong_token",
    },
  );
  assertEquals(await checkDns(NAME, TOKEN, doh({ Status: 3 }).f), {
    kind: "dns_no_txt",
    reason: "nxdomain",
  });
  assertEquals(await checkDns(NAME, TOKEN, doh({ Status: 0 }).f), {
    kind: "dns_no_txt",
    reason: "no_txt",
  });
  assertEquals(await checkDns(NAME, TOKEN, doh({ Status: 2 }).f), { kind: "resolver_error" });
  assertEquals(await checkDns(NAME, TOKEN, doh({}, 503).f), { kind: "resolver_error" });
  assertEquals(await checkDns(NAME, TOKEN, () => Promise.reject(new Error("timeout"))), {
    kind: "resolver_error",
  });
});

Deno.test(
  "handleVerify records the outcome; a resolver error leaves the claim pending",
  async () => {
    const recorded: unknown[] = [];
    const claim = { status: "pending", method: "dns_txt", dns_name: NAME, token: TOKEN };
    const deps = (body: unknown, status = 200) => ({
      claimCheck: () => Promise.resolve(claim as Record<string, unknown>),
      record: (r: Record<string, unknown>[]) => {
        recorded.push(...r);
        return Promise.resolve({ recorded: 1 });
      },
      fetch: doh(body, status).f,
    });
    assertEquals(
      await handleVerify(
        { claim_id: CLAIM },
        deps({ Status: 0, Answer: [{ type: 16, data: `"${TOKEN}"` }] }),
      ),
      { status: 200, body: { status: "verified" } },
    );
    assertEquals(recorded, [{ claim_id: CLAIM, outcome: "verified", method: "dns_txt" }]);
    recorded.length = 0;
    assertEquals((await handleVerify({ claim_id: CLAIM }, deps({}, 502))).body, {
      status: "pending",
      checked: "resolver_error",
    });
    assertEquals(recorded, []);
    assertEquals((await handleVerify({ claim_id: CLAIM }, deps({ Status: 3 }))).body, {
      status: "pending",
      checked: "nxdomain",
    });
    assertEquals(recorded, [
      { claim_id: CLAIM, outcome: "dns_no_txt", method: "dns_txt", reason: "nxdomain" },
    ]);
    assertEquals((await handleVerify({ claim_id: "x" }, deps({}))).status, 400);
  },
);

Deno.test("other methods are only queued; nothing is fetched", async () => {
  let fetched = 0;
  const out = await handleVerify(
    { claim_id: CLAIM },
    {
      claimCheck: () => Promise.resolve({ status: "pending", method: "meta" }),
      record: () => Promise.resolve(null),
      fetch: () => {
        fetched++;
        return Promise.resolve(new Response("{}"));
      },
    },
  );
  assertEquals(out.body, { status: "pending", checked: "queued" });
  assertEquals(fetched, 0);
});
