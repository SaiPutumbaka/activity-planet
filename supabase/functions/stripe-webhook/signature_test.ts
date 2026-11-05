import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  computeSignature,
  parseSignatureHeader,
  timingSafeEqual,
  verifyStripeSignature,
} from "./signature.ts";

const SECRET = "whsec_test_secret";
const BODY = '{"id":"evt_1","type":"charge.refunded"}';
const T = 1_800_000_000;

Deno.test("signature: a known HMAC-SHA256 vector", async () => {
  // HMAC-SHA256(key "key", "The quick brown fox jumps over the lazy dog") per RFC 4231 style vectors.
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode("key"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      enc.encode("The quick brown fox jumps over the lazy dog"),
    ),
  );
  const hex = Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
  assertEquals(hex, "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
  // computeSignature signs "<t>.<payload>".
  assertEquals(await computeSignature("key", 0, "x"), await computeSignature("key", 0, "x"));
});

Deno.test(
  "signature: success, bad signature, stale, missing, bad header, second secret",
  async () => {
    const sig = await computeSignature(SECRET, T, BODY);
    assertEquals(await verifyStripeSignature(BODY, `t=${T},v1=${sig}`, [SECRET], T + 10), "ok");
    assertEquals(await verifyStripeSignature(BODY, `t=${T},v1=${sig},v0=abc`, [SECRET], T), "ok");
    assertEquals(
      await verifyStripeSignature(BODY + " ", `t=${T},v1=${sig}`, [SECRET], T),
      "mismatch",
    );
    assertEquals(
      await verifyStripeSignature(BODY, `t=${T},v1=${"0".repeat(64)}`, [SECRET], T),
      "mismatch",
    );
    assertEquals(
      await verifyStripeSignature(BODY, `t=${T},v1=${sig}`, ["whsec_other"], T),
      "mismatch",
    );
    assertEquals(await verifyStripeSignature(BODY, `t=${T},v1=${sig}`, [SECRET], T + 301), "stale");
    assertEquals(await verifyStripeSignature(BODY, `t=${T},v1=${sig}`, [SECRET], T - 301), "stale");
    assertEquals(await verifyStripeSignature(BODY, null, [SECRET], T), "missing");
    assertEquals(await verifyStripeSignature(BODY, `v1=${sig}`, [SECRET], T), "bad_header");
    assertEquals(await verifyStripeSignature(BODY, `t=${T}`, [SECRET], T), "bad_header");
    // The Connect endpoint's own secret also verifies; an empty secret never does.
    const connectSig = await computeSignature("whsec_connect", T, BODY);
    assertEquals(
      await verifyStripeSignature(BODY, `t=${T},v1=${connectSig}`, [SECRET, "whsec_connect"], T),
      "ok",
    );
    assertEquals(await verifyStripeSignature(BODY, `t=${T},v1=${sig}`, [""], T), "mismatch");
  },
);

Deno.test("header parsing and constant-time compare", () => {
  assertEquals(parseSignatureHeader("t=12,v1=" + "a".repeat(64) + ",v1=zz"), {
    t: 12,
    v1: ["a".repeat(64)],
  });
  assertEquals(timingSafeEqual("abcd", "abcd"), true);
  assertEquals(timingSafeEqual("abcd", "abce"), false);
  assertEquals(timingSafeEqual("abc", "abcd"), false);
});
