// Web push for send-notifications (PLAN.md 4.9, 4.10): VAPID (RFC 8292) and the aes128gcm
// payload encryption (RFC 8291 over RFC 8188), in WebCrypto only, so the function needs no npm
// package and no Node crypto. Free: the browsers' push services charge nothing.
//
//   const vapid = await importVapidKeys(publicKey, privateKey, subject)  // base64url raw keys
//   const req = await buildPushRequest(subscription, payload, vapid, { ttl, urgency })
//   const res = await fetch(req.url, req.init)
//   classifyPushStatus(res.status)                                        // ok | gone | retry | failed
//
// Keys: VAPID_PUBLIC_KEY is the 65-byte uncompressed P-256 point and VAPID_PRIVATE_KEY the
// 32-byte private scalar, both base64url (the format `npx web-push generate-vapid-keys` prints).
// VAPID_SUBJECT is a mailto: or https: contact for the push services.

const enc = new TextEncoder();

export function b64urlEncode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function b64urlDecode(value: string): Uint8Array {
  const clean = value.trim().replaceAll("-", "+").replaceAll("_", "/").replace(/=+$/, "");
  if (!/^[A-Za-z0-9+/]*$/.test(clean)) throw new Error("bad_base64url");
  const padded = clean + "=".repeat((4 - (clean.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

async function hmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

/** JWK for a P-256 key from its raw uncompressed public point (and optional private scalar). */
function p256Jwk(publicRaw: Uint8Array, privateRaw?: Uint8Array): JsonWebKey {
  if (publicRaw.length !== 65 || publicRaw[0] !== 4) throw new Error("bad_public_key");
  const jwk: JsonWebKey = {
    kty: "EC",
    crv: "P-256",
    x: b64urlEncode(publicRaw.slice(1, 33)),
    y: b64urlEncode(publicRaw.slice(33, 65)),
    ext: true,
  };
  if (privateRaw) {
    if (privateRaw.length !== 32) throw new Error("bad_private_key");
    jwk.d = b64urlEncode(privateRaw);
  }
  return jwk;
}

export interface VapidKeys {
  publicKey: string; // base64url, as sent in the k= parameter
  privateKey: CryptoKey; // ECDSA P-256, sign
  subject: string;
}

export async function importVapidKeys(
  publicKey: string,
  privateKey: string,
  subject: string,
): Promise<VapidKeys> {
  if (!/^(mailto:|https:\/\/)/.test(subject)) throw new Error("bad_vapid_subject");
  const pub = b64urlDecode(publicKey);
  const key = await crypto.subtle.importKey(
    "jwk",
    p256Jwk(pub, b64urlDecode(privateKey)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  return { publicKey: b64urlEncode(pub), privateKey: key, subject };
}

/** The VAPID JWT (ES256) for one push service origin, valid for 12 hours. */
export async function vapidJwt(
  vapid: VapidKeys,
  audience: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<string> {
  const header = b64urlEncode(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = b64urlEncode(
    enc.encode(JSON.stringify({ aud: audience, exp: nowSeconds + 12 * 3600, sub: vapid.subject })),
  );
  const signingInput = `${header}.${claims}`;
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      vapid.privateKey,
      enc.encode(signingInput),
    ),
  );
  return `${signingInput}.${b64urlEncode(sig)}`;
}

export interface PushSubscriptionKeys {
  endpoint: string;
  p256dh: string;
  auth: string;
}

/** Fixed sender key and salt, for the RFC 8291 test vector only. */
export interface EncryptOverrides {
  senderPublic: Uint8Array;
  senderPrivate: Uint8Array;
  salt: Uint8Array;
}

const RECORD_SIZE = 4096;

/**
 * RFC 8291: encrypts one push message for a subscription as a single aes128gcm record
 * (header: salt, record size, the sender's public key as key id).
 */
export async function encryptPayload(
  sub: Pick<PushSubscriptionKeys, "p256dh" | "auth">,
  plaintext: Uint8Array,
  overrides?: EncryptOverrides,
): Promise<Uint8Array> {
  const uaPublic = b64urlDecode(sub.p256dh);
  const authSecret = b64urlDecode(sub.auth);
  if (uaPublic.length !== 65 || authSecret.length < 16) throw new Error("bad_subscription_keys");
  if (plaintext.length > RECORD_SIZE - 17 - 86) throw new Error("payload_too_large");

  let asPublic: Uint8Array;
  let asPrivate: CryptoKey;
  if (overrides) {
    asPublic = overrides.senderPublic;
    asPrivate = await crypto.subtle.importKey(
      "jwk",
      p256Jwk(overrides.senderPublic, overrides.senderPrivate),
      { name: "ECDH", namedCurve: "P-256" },
      false,
      ["deriveBits"],
    );
  } else {
    const pair = (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, [
      "deriveBits",
    ])) as CryptoKeyPair;
    asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
    asPrivate = pair.privateKey;
  }
  const uaKey = await crypto.subtle.importKey(
    "raw",
    uaPublic,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  const ecdhSecret = new Uint8Array(
    await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, asPrivate, 256),
  );

  // IKM = HKDF(auth_secret, ecdh_secret, "WebPush: info" || 0 || ua_public || as_public, 32)
  const prkKey = await hmac(authSecret, ecdhSecret);
  const keyInfo = concat(enc.encode("WebPush: info\0"), uaPublic, asPublic, new Uint8Array([1]));
  const ikm = (await hmac(prkKey, keyInfo)).slice(0, 32);

  const salt = overrides?.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const prk = await hmac(salt, ikm);
  const cek = (
    await hmac(prk, concat(enc.encode("Content-Encoding: aes128gcm\0"), new Uint8Array([1])))
  ).slice(0, 16);
  const nonce = (
    await hmac(prk, concat(enc.encode("Content-Encoding: nonce\0"), new Uint8Array([1])))
  ).slice(0, 12);

  const aes = await crypto.subtle.importKey("raw", cek, { name: "AES-GCM" }, false, ["encrypt"]);
  // One record: the plaintext and the last-record delimiter 0x02, no padding.
  const record = concat(plaintext, new Uint8Array([2]));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, aes, record),
  );

  const header = new Uint8Array(16 + 4 + 1 + asPublic.length);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, RECORD_SIZE);
  header[20] = asPublic.length;
  header.set(asPublic, 21);
  return concat(header, ciphertext);
}

/**
 * Push services the worker posts to. A subscription endpoint is chosen by the browser, but the
 * row is written by the client, so anything else is refused (no requests to arbitrary hosts).
 */
const PUSH_HOSTS = [
  /^fcm\.googleapis\.com$/,
  /^android\.googleapis\.com$/,
  /^updates\.push\.services\.mozilla\.com$/,
  /^push\.services\.mozilla\.com$/,
  /^(?:[a-z0-9-]+\.)*push\.apple\.com$/,
  /^(?:[a-z0-9-]+\.)*notify\.windows\.com$/,
];

export function allowedEndpoint(endpoint: string): boolean {
  try {
    const u = new URL(endpoint);
    return u.protocol === "https:" && !u.port && PUSH_HOSTS.some((re) => re.test(u.hostname));
  } catch {
    return false;
  }
}

export interface PushOptions {
  ttl: number; // seconds the push service may hold it
  urgency: "very-low" | "low" | "normal" | "high";
  topic?: string; // replaces an undelivered push with the same topic (<= 32 base64url chars)
}

export async function buildPushRequest(
  sub: PushSubscriptionKeys,
  payload: unknown,
  vapid: VapidKeys,
  opts: PushOptions,
): Promise<{ url: string; init: RequestInit }> {
  if (!allowedEndpoint(sub.endpoint)) throw new Error("endpoint_not_allowed");
  const body = await encryptPayload(sub, enc.encode(JSON.stringify(payload)));
  const audience = new URL(sub.endpoint).origin;
  const jwt = await vapidJwt(vapid, audience);
  const headers: Record<string, string> = {
    Authorization: `vapid t=${jwt}, k=${vapid.publicKey}`,
    "Content-Encoding": "aes128gcm",
    "Content-Type": "application/octet-stream",
    TTL: String(Math.max(0, Math.floor(opts.ttl))),
    Urgency: opts.urgency,
  };
  if (opts.topic && /^[A-Za-z0-9_-]{1,32}$/.test(opts.topic)) headers.Topic = opts.topic;
  return { url: sub.endpoint, init: { method: "POST", headers, body } };
}

export type PushOutcome = "ok" | "gone" | "retry" | "failed";

/** 404 and 410: the subscription is gone (revoke the device). 429 and 5xx: try again later. */
export function classifyPushStatus(status: number): PushOutcome {
  if (status >= 200 && status < 300) return "ok";
  if (status === 404 || status === 410) return "gone";
  if (status === 429 || status >= 500) return "retry";
  return "failed";
}
