// deno test --allow-read supabase/functions/image-guard
//
// Pins the perceptual hashes and the match rule that migration 52 holds in image_hash_close
// (pHash within 10 bits and dHash within 16, neither dHash near-constant). The fixtures are
// synthetic 256 x 256 pictures (no real photos): base.jpg and copies of it re-encoded, resized,
// cropped, brightened, made grayscale, palette-reduced and given an alpha channel, plus five
// unrelated pictures and two flat colour blocks.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.19";

import { decodeImage, sniffFormat } from "./decode.ts";
import { boxResize, hamming, hashPixels, type ImageHashes, sha256Hex, toGray } from "./hash.ts";

const dir = new URL("./fixtures/", import.meta.url);
const read = (name: string) => Deno.readFile(new URL(name, dir));

async function hashesOf(name: string): Promise<ImageHashes> {
  const px = decodeImage(await read(name));
  assert(px, `${name} decodes`);
  return hashPixels(px);
}

function popcount(hex: string): number {
  return hamming(hex, "0000000000000000");
}

/** The database rule (image_hash_close, migration 52), mirrored for the tests. */
function close(a: ImageHashes, b: ImageHashes): boolean {
  const dOk = (d: string) => popcount(d) >= 4 && popcount(d) <= 60;
  return (
    dOk(a.dhash) &&
    dOk(b.dhash) &&
    hamming(a.phash, b.phash) <= 10 &&
    hamming(a.dhash, b.dhash) <= 16
  );
}

const COPIES = [
  "base_q35.jpg",
  "base_small.jpg",
  "base_crop.jpg",
  "base_bright.jpg",
  "base_gray.png",
  "base_pal.png",
  "base_rgba.png",
];
const OTHERS = ["other2.jpg", "other3.jpg", "other4.jpg", "other5.jpg", "other6.jpg"];

Deno.test("hashes are 16 hex characters and stable", async () => {
  const h = await hashesOf("base.jpg");
  assertEquals(h, { phash: "cd73ca7ac411565a", dhash: "fefcf9797d7f071f" });
});

Deno.test("every copy of the base picture matches it", async () => {
  const base = await hashesOf("base.jpg");
  for (const name of COPIES) {
    const h = await hashesOf(name);
    assert(
      close(base, h),
      `${name} p=${hamming(base.phash, h.phash)} d=${hamming(base.dhash, h.dhash)}`,
    );
  }
});

Deno.test("unrelated pictures match nothing, neither the base nor each other", async () => {
  const all = [await hashesOf("base.jpg"), ...(await Promise.all(OTHERS.map(hashesOf)))];
  for (let i = 0; i < all.length; i++) {
    for (let j = i + 1; j < all.length; j++) assertFalse(close(all[i]!, all[j]!), `${i} vs ${j}`);
  }
});

Deno.test("flat colour blocks never match by perceptual hash", async () => {
  const gray = await hashesOf("flat_gray.jpg");
  const green = await hashesOf("flat_green.jpg");
  assertEquals(gray.dhash, "0000000000000000");
  assertFalse(close(gray, green));
  assertFalse(close(gray, gray));
});

Deno.test("formats: JPEG and PNG decode, WebP and junk do not", async () => {
  assertEquals(sniffFormat(await read("base.jpg")), "jpeg");
  assertEquals(sniffFormat(await read("base_pal.png")), "png");
  assertEquals(sniffFormat(await read("base.webp")), "unknown");
  assertEquals(decodeImage(await read("base.webp")), null);
  assertEquals(decodeImage(new Uint8Array([0xff, 0xd8, 0xff, 0x00, 0x01])), null);
  assertEquals(decodeImage(new Uint8Array(0)), null);
});

Deno.test("sha256 tells exact copies apart from re-encodes", async () => {
  const a = await sha256Hex(await read("base.jpg"));
  assertEquals(a, await sha256Hex(await read("base.jpg")));
  assert(/^[0-9a-f]{64}$/.test(a));
  assert(a !== (await sha256Hex(await read("base_q35.jpg"))));
});

Deno.test("helpers: gray composites alpha over white, box resize averages", () => {
  const g = toGray({
    width: 2,
    height: 1,
    channels: 4,
    data: new Uint8Array([0, 0, 0, 0, 0, 0, 0, 255]),
  });
  assertEquals(Array.from(g), [255, 0]);
  const r = boxResize(new Float64Array([0, 10, 20, 30]), 2, 2, 1, 1);
  assertEquals(Array.from(r), [15]);
  assertEquals(hamming("ffffffffffffffff", "0000000000000000"), 64);
});
