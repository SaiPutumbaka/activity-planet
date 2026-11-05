// Stripe-Signature verification (design section 9.4): HMAC-SHA256 over "<t>.<payload>" with Web
// Crypto, a 300-second tolerance and a constant-time compare. Any of the given secrets may match
// (the platform endpoint and, when set, the Connect endpoint).

export type SignatureResult = "ok" | "missing" | "bad_header" | "stale" | "mismatch";

export function parseSignatureHeader(header: string): { t: number | null; v1: string[] } {
  let t: number | null = null;
  const v1: string[] = [];
  for (const part of header.split(",")) {
    const i = part.indexOf("=");
    if (i < 1) continue;
    const key = part.slice(0, i).trim();
    const value = part.slice(i + 1).trim();
    if (key === "t" && /^\d{1,12}$/.test(value)) t = Number(value);
    else if (key === "v1" && /^[0-9a-f]{64}$/.test(value)) v1.push(value);
  }
  return { t, v1 };
}

export async function computeSignature(
  secret: string,
  timestamp: number,
  payload: string,
): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${timestamp}.${payload}`));
  return Array.from(new Uint8Array(mac), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Compares two equal-length hex strings without an early exit. */
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function verifyStripeSignature(
  payload: string,
  header: string | null,
  secrets: string[],
  nowSeconds: number,
  toleranceSeconds = 300,
): Promise<SignatureResult> {
  if (!header) return "missing";
  const { t, v1 } = parseSignatureHeader(header);
  if (t === null || v1.length === 0) return "bad_header";
  if (Math.abs(nowSeconds - t) > toleranceSeconds) return "stale";
  let match = false;
  for (const secret of secrets.filter((s) => s.length > 0)) {
    const expected = await computeSignature(secret, t, payload);
    for (const sig of v1) if (timingSafeEqual(expected, sig)) match = true;
  }
  return match ? "ok" : "mismatch";
}
