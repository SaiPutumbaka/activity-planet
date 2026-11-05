// deno test supabase/functions/send-notifications
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";
import {
  allowedEndpoint,
  b64urlDecode,
  b64urlEncode,
  buildPushRequest,
  classifyPushStatus,
  encryptPayload,
  importVapidKeys,
  vapidJwt,
} from "./webpush.ts";

// RFC 8291 Appendix A: the full worked example, byte for byte.
Deno.test("aes128gcm matches the RFC 8291 test vector", async () => {
  const out = await encryptPayload(
    {
      p256dh:
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
      auth: "BTBZMqHH6r4Tts7J_aSIgg",
    },
    new TextEncoder().encode("When I grow up, I want to be a watermelon"),
    {
      senderPublic: b64urlDecode(
        "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
      ),
      senderPrivate: b64urlDecode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"),
      salt: b64urlDecode("DGv6ra1nlYgDCS1FRnbzlw"),
    },
  );
  assertEquals(
    b64urlEncode(out),
    "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
  );
});

async function newVapid() {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  return { pub: b64urlEncode(pub), priv: jwk.d!, verifyKey: pair.publicKey };
}

Deno.test("VAPID JWT is ES256, verifies with the public key, names the audience", async () => {
  const k = await newVapid();
  const vapid = await importVapidKeys(k.pub, k.priv, "mailto:ops@example.com");
  const jwt = await vapidJwt(vapid, "https://fcm.googleapis.com", 1_000_000);
  const [h, c, s] = jwt.split(".");
  assertEquals(JSON.parse(new TextDecoder().decode(b64urlDecode(h))), { typ: "JWT", alg: "ES256" });
  const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(c)));
  assertEquals(claims, {
    aud: "https://fcm.googleapis.com",
    exp: 1_000_000 + 43200,
    sub: "mailto:ops@example.com",
  });
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    k.verifyKey,
    b64urlDecode(s),
    new TextEncoder().encode(`${h}.${c}`),
  );
  assert(ok);
});

Deno.test("VAPID subject must be mailto: or https:", async () => {
  const k = await newVapid();
  await assertRejects(() => importVapidKeys(k.pub, k.priv, "ops@example.com"));
});

Deno.test("push request headers and endpoint allow-list", async () => {
  const k = await newVapid();
  const vapid = await importVapidKeys(k.pub, k.priv, "https://activityplanet.app");
  const ua = (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, [
    "deriveBits",
  ])) as CryptoKeyPair;
  const sub = {
    endpoint: "https://fcm.googleapis.com/fcm/send/abc",
    p256dh: b64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw", ua.publicKey))),
    auth: b64urlEncode(crypto.getRandomValues(new Uint8Array(16))),
  };
  const { url, init } = await buildPushRequest(sub, { title: "Hi" }, vapid, {
    ttl: 60,
    urgency: "high",
  });
  const headers = init.headers as Record<string, string>;
  assertEquals(url, sub.endpoint);
  assertEquals(headers["Content-Encoding"], "aes128gcm");
  assertEquals(headers.TTL, "60");
  assertEquals(headers.Urgency, "high");
  assert(headers.Authorization.startsWith("vapid t="));
  assert(headers.Authorization.endsWith(`, k=${k.pub}`));
  await assertRejects(() =>
    buildPushRequest({ ...sub, endpoint: "https://evil.example.com/x" }, {}, vapid, {
      ttl: 1,
      urgency: "low",
    }),
  );
  assert(allowedEndpoint("https://updates.push.services.mozilla.com/wpush/v2/x"));
  assert(allowedEndpoint("https://web.push.apple.com/abc"));
  assert(allowedEndpoint("https://wns2-by3p.notify.windows.com/w/?token=x"));
  assert(!allowedEndpoint("http://fcm.googleapis.com/fcm/send/abc"));
  assert(!allowedEndpoint("https://fcm.googleapis.com:8443/x"));
  assert(!allowedEndpoint("https://push.apple.com.evil.example/x"));
  assert(!allowedEndpoint("https://169.254.169.254/latest"));
});

Deno.test("push status classes: 404 and 410 revoke", () => {
  assertEquals(classifyPushStatus(201), "ok");
  assertEquals(classifyPushStatus(404), "gone");
  assertEquals(classifyPushStatus(410), "gone");
  assertEquals(classifyPushStatus(429), "retry");
  assertEquals(classifyPushStatus(503), "retry");
  assertEquals(classifyPushStatus(400), "failed");
  assertEquals(classifyPushStatus(403), "failed");
});
