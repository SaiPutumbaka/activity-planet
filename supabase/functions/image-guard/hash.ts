// image-guard: perceptual hashes (PLAN 4.11, Take It Down Act copies; the logic only, no I/O).
//
// Two 64-bit hashes of a decoded image, each returned as 16 lowercase hex characters (the bits
// read row by row, most significant first), plus the helpers the tests use:
//
//   pHash  grayscale, box-downscaled to 32 x 32, 2-D DCT-II, the 8 x 8 lowest frequencies; a
//          bit is 1 when its coefficient is above the median of the 63 non-DC coefficients.
//          Survives re-encoding, resizing, mild colour and brightness changes.
//   dHash  grayscale, box-downscaled to 9 x 8; a bit is 1 when a pixel is brighter than its right
//          neighbour. Cheap second opinion that rejects pHash coincidences on flat images.
//
// Only these hashes (and a SHA-256 of the bytes) are ever stored; the image itself is not kept
// anywhere by image-guard. Matching thresholds live in the database (image_hash_close, migration
// 52) so the queue, the upload check and the copy sweep all use one rule.

/** Decoded pixels: `channels` interleaved 8-bit samples per pixel (1 gray, 2 gray+alpha, 3 RGB, 4 RGBA). */
export interface Pixels {
  width: number;
  height: number;
  channels: 1 | 2 | 3 | 4;
  data: Uint8Array | Uint8ClampedArray;
}

export interface ImageHashes {
  phash: string;
  dhash: string;
}

/** Luminance per pixel (0..255); transparent pixels are composited over white. */
export function toGray(img: Pixels): Float64Array {
  const { width, height, channels, data } = img;
  const n = width * height;
  if (width < 1 || height < 1 || data.length < n * channels) throw new Error("bad_pixels");
  const out = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const o = i * channels;
    let lum: number;
    let alpha = 1;
    if (channels === 1 || channels === 2) {
      lum = data[o]!;
      if (channels === 2) alpha = data[o + 1]! / 255;
    } else {
      lum = 0.299 * data[o]! + 0.587 * data[o + 1]! + 0.114 * data[o + 2]!;
      if (channels === 4) alpha = data[o + 3]! / 255;
    }
    out[i] = alpha * lum + (1 - alpha) * 255;
  }
  return out;
}

/** Area-average downscale of a gray image to w x h (nearest sample when upscaling). */
export function boxResize(
  gray: Float64Array,
  width: number,
  height: number,
  w: number,
  h: number,
): Float64Array {
  const out = new Float64Array(w * h);
  for (let ty = 0; ty < h; ty++) {
    const y0 = Math.floor((ty * height) / h);
    const y1 = Math.max(y0 + 1, Math.floor(((ty + 1) * height) / h));
    for (let tx = 0; tx < w; tx++) {
      const x0 = Math.floor((tx * width) / w);
      const x1 = Math.max(x0 + 1, Math.floor(((tx + 1) * width) / w));
      let sum = 0;
      for (let y = y0; y < y1; y++) {
        const row = y * width;
        for (let x = x0; x < x1; x++) sum += gray[row + x]!;
      }
      out[ty * w + tx] = sum / ((y1 - y0) * (x1 - x0));
    }
  }
  return out;
}

function bitsToHex(bits: boolean[]): string {
  let hex = "";
  for (let i = 0; i < bits.length; i += 4) {
    const nibble =
      (bits[i] ? 8 : 0) | (bits[i + 1] ? 4 : 0) | (bits[i + 2] ? 2 : 0) | (bits[i + 3] ? 1 : 0);
    hex += nibble.toString(16);
  }
  return hex;
}

const N = 32;
const COS: Float64Array = (() => {
  const t = new Float64Array(N * N);
  for (let u = 0; u < N; u++) {
    for (let x = 0; x < N; x++) t[u * N + x] = Math.cos(((2 * x + 1) * u * Math.PI) / (2 * N));
  }
  return t;
})();

/** 64-bit DCT perceptual hash of a gray image. */
export function phashGray(gray: Float64Array, width: number, height: number): string {
  const s = boxResize(gray, width, height, N, N);
  // Separable DCT-II, only the 8 lowest frequencies in each direction.
  const rows = new Float64Array(N * 8); // rows[y][u]
  for (let y = 0; y < N; y++) {
    for (let u = 0; u < 8; u++) {
      let acc = 0;
      for (let x = 0; x < N; x++) acc += s[y * N + x]! * COS[u * N + x]!;
      rows[y * 8 + u] = acc;
    }
  }
  const coef: number[] = [];
  for (let v = 0; v < 8; v++) {
    for (let u = 0; u < 8; u++) {
      let acc = 0;
      for (let y = 0; y < N; y++) acc += rows[y * 8 + u]! * COS[v * N + y]!;
      coef.push(acc);
    }
  }
  const ac = coef.slice(1).sort((a, b) => a - b);
  const median = (ac[31]! + ac[32]!) / 2;
  return bitsToHex(coef.map((c) => c > median));
}

/** 64-bit difference hash of a gray image. */
export function dhashGray(gray: Float64Array, width: number, height: number): string {
  const s = boxResize(gray, width, height, 9, 8);
  const bits: boolean[] = [];
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) bits.push(s[y * 9 + x]! > s[y * 9 + x + 1]!);
  }
  return bitsToHex(bits);
}

export function hashPixels(img: Pixels): ImageHashes {
  const gray = toGray(img);
  return {
    phash: phashGray(gray, img.width, img.height),
    dhash: dhashGray(gray, img.width, img.height),
  };
}

/** Number of differing bits between two 16-character hex hashes. */
export function hamming(a: string, b: string): number {
  if (!/^[0-9a-f]{16}$/.test(a) || !/^[0-9a-f]{16}$/.test(b)) throw new Error("bad_hash");
  let x = BigInt("0x" + a) ^ BigInt("0x" + b);
  let n = 0;
  while (x) {
    n += Number(x & 1n);
    x >>= 1n;
  }
  return n;
}

/** Lowercase hex SHA-256 of the bytes (exact copies). */
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
