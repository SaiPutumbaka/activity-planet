// image-guard: decode JPEG or PNG bytes into pixels for hash.ts (pure JavaScript decoders, no
// native code and no paid API). The app only ever uploads a 512 x 512 JPEG it re-encoded itself
// (apps/app/src/lib/avatar.ts), so anything that is neither JPEG nor PNG, or does not decode, is
// reported as unreadable and the caller treats it as not allowed.
import jpeg from "npm:jpeg-js@0.4.4";
import { decode as decodePng } from "npm:fast-png@6.4.0";

import type { Pixels } from "./hash.ts";

export type ImageFormat = "jpeg" | "png" | "unknown";

/** Largest image decoded: 40 megapixels (the bucket's 2 MiB cap keeps real uploads far below). */
const MAX_PIXELS = 40_000_000;

export function sniffFormat(bytes: Uint8Array): ImageFormat {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "jpeg";
  }
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    return "png";
  }
  return "unknown";
}

/** Pixels, or null when the bytes are not a JPEG or PNG this decoder can read. */
export function decodeImage(bytes: Uint8Array): Pixels | null {
  const format = sniffFormat(bytes);
  try {
    if (format === "jpeg") {
      const img = jpeg.decode(bytes, {
        useTArray: true,
        formatAsRGBA: true,
        maxResolutionInMP: MAX_PIXELS / 1_000_000,
        maxMemoryUsageInMB: 512,
      });
      return { width: img.width, height: img.height, channels: 4, data: img.data };
    }
    if (format === "png") {
      const img = decodePng(bytes);
      if (img.width * img.height > MAX_PIXELS) return null;
      return pngToPixels(img);
    }
  } catch {
    return null;
  }
  return null;
}

interface DecodedPng {
  width: number;
  height: number;
  channels: number;
  depth: number;
  data: ArrayLike<number>;
  palette?: ArrayLike<ArrayLike<number>>;
}

/** Sample i of a row-padded buffer of `depth`-bit samples (fast-png leaves depths below 8 packed). */
function sampleAt(
  data: ArrayLike<number>,
  depth: number,
  rowBytes: number,
  perRow: number,
  i: number,
): number {
  if (depth >= 8) return data[i]!;
  const row = Math.floor(i / perRow);
  const bit = (i % perRow) * depth;
  const byte = data[row * rowBytes + (bit >> 3)]!;
  return (byte >> (8 - depth - (bit & 7))) & ((1 << depth) - 1);
}

function pngToPixels(img: DecodedPng): Pixels | null {
  const n = img.width * img.height;
  const channels = img.channels;
  if (channels < 1 || channels > 4) return null;
  const perRow = img.width * channels;
  const rowBytes = Math.ceil((perRow * img.depth) / 8);
  if (img.depth < 8 && img.data.length < rowBytes * img.height) return null;
  if (img.palette) {
    const out = new Uint8Array(n * 4);
    for (let i = 0; i < n; i++) {
      const entry = img.palette[sampleAt(img.data, img.depth, rowBytes, perRow, i)];
      if (!entry) return null;
      out[i * 4] = entry[0]!;
      out[i * 4 + 1] = entry[1]!;
      out[i * 4 + 2] = entry[2]!;
      out[i * 4 + 3] = entry.length > 3 ? entry[3]! : 255;
    }
    return { width: img.width, height: img.height, channels: 4, data: out };
  }
  const shift = img.depth === 16 ? 8 : 0;
  const scale = img.depth < 8 ? 255 / ((1 << img.depth) - 1) : 1;
  const out = new Uint8Array(n * channels);
  for (let i = 0; i < n * channels; i++) {
    const v = sampleAt(img.data, img.depth, rowBytes, perRow, i);
    out[i] = Math.min(255, Math.round((v >> shift) * scale));
  }
  return { width: img.width, height: img.height, channels: channels as 1 | 2 | 3 | 4, data: out };
}
